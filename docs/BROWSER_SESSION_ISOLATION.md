# Browser session isolation per task

Status: implemented. Sections 1 to 6 describe the rules, the structure and their limits; sections 7 to 11 describe
how profiles are stored, how cookies are copied, importing sign-ins from another browser, and how tasks follow the
person's sign-ins. The browser host contract is in [BROWSER_HOST](BROWSER_HOST.md) section 3, "Profiles", and the vault
is in [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md).

## 1. Background and goals

An AI browser should share things like credentials across tasks, but keep separate for each task the values that
cookies, sessions and local storage carry, such as the account currently signed in, so that two tasks signed in to the
same site with different accounts do not overwrite each other.

With Settings › General "Keep cookies" set to "Per task" (the default), all tasks share the vault's credentials
(passwords, TOTP, Yardlet passkeys) and Touch ID passkeys, and each task keeps its own sign-in state (cookies,
localStorage, sessionStorage, IndexedDB, cache) in its own profile. The person's sign-ins still reach every task that
follows the site (section 3). With "Shared by all tasks", the tabs of all tasks use the single default profile
(`~/Library/Application Support/Yardlet/Browser/Default`).

## 2. How the two apps and other browsers do it

The bundles were read as bytes only (not run). Aside and Ego were read through their makers' docs.

| Product | Sign-in state per task | Evidence |
|---|---|---|
| Claude app 3.1623.3 | Chosen with the "Keep cookies" setting: "Until quit" (default, not persistent, per working folder), "Shared" (shared by all sessions, `persist:launch-preview-cowork-shared`), "Per session" (`persist:launch-preview-session-<session ID>` for each session). Forking a session copies the parent's cookies (`seedForkedPreviewCookies`). Deleting a session clears that session's storage (`clearData`); archiving does not. The agent and the person use the same tab's storage | `app.asar` `index.chunk-DylQWxwC.js` (`launchPreviewStorage: "none" \| "shared" \| "session"`), the setting text in `ion-dist` |
| Codex app 26.1016 | None. All threads of the local built-in browser use the single `persist:codex-browser-app`. Only tab ownership and restore information differ per thread, and archiving or deleting does not clear the sign-in storage | `main-JI9qDiXp.js` (`session.fromPartition(Vu("app"))`), `src-CSKkIr_z.js` |
| Aside | Tasks share the default profile, and only "Incognito" tasks run without profile state. The vault (Aside Vault) shares credentials | Help page Run tasks |
| Claude app 3.6556.2 (import) | Behind the feature flag `desktop_ccd_chrome_import` there is "Import sign-ins from Chrome": choose a Chrome, Edge, Brave, Chromium or Firefox profile and then sites (registrable domains), and their cookies and localStorage go into the preview storage. Existing cookies are overwritten, not cleared, and there is a list of imported sites with a way to remove them (section 10) | `app.asar` `index.chunk-TCY6lWOp.js` (`runChromeImport`, `listChromeImportSites`) |
| ego(lite) | One BrowserContext per Space (task), with its own cookies and storage. Even so, the agent picks up the sign-ins already in the browser (the docs do not say how they are carried over). A Profile can also be assigned to a task | Docs Space, changelog 0.4.4.15 |

Yardlet combines the Claude app's "Per session" and ego(lite)'s Space: storage per task, new tasks start signed in, and
credentials are shared through the vault.

## 3. Rules

These are the rules of "Per task". How sign-ins are found and passed on is in section 11.

| Question | Rule | Reason |
|---|---|---|
| Disk folder or memory | A disk folder per task (`Browser/Task-<key>`, the `cache_path` of `CefRequestContext`), directly under the root cache, because Chromium opens only such a folder as a disk profile (section 7) | The host ends 60 seconds after it has no tabs. With an in-memory context, sign-ins would be lost every time |
| What a new task starts with | A copy of the default profile's cookies. A child task starts with its parent task's cookies and inherits its parent's own sign-ins. localStorage and IndexedDB are not copied (on such sites the vault signs in again) | Signing in again every time would bring new-device alerts and two-step verification in every task. The Claude app also copies the parent's cookies on fork |
| The person's sign-ins | Whether with a password, a passkey, "Sign in with Google" or single sign-on, the site's (registrable domain's) cookies go to the default profile and to every task that follows the site: at once to tasks with tabs open, to the rest when their tab next opens. A sign-in the person makes on a page the agent handed over is the person's too, and so is a sign-in imported from another browser (section 10) | As in the Codex app, every task normally uses the same sign-ins |
| A task's own sign-ins | A site a task signed in to itself (its agent filled the sign-in from the vault, or typed it into a password or code field) stays that task's: the task stops following that site, the person's later sign-ins elsewhere do not overwrite it, and a sign-in the person makes again in that task is not passed to other tasks | Only a task that went in with another account keeps its own sign-in |
| Task profiles from before following | The first time such a task's tab opens, it fills in from the default profile only the sites it has no cookie of at all; sites that already have cookies stay as they are | Filling never overwrites |
| Tabs on the new task screen | The new task screen has its own profile key, and the task its tab moves to keeps using that key. The new task screen gets a new key | The moved tab's page stays as it is, so its storage must stay the same too |
| Archive and delete | Both delete that task's folder. When the host does not have the folders open (when the host ends), folders that belong to no remaining task are deleted, along with the record of that profile that Chromium left in `Local State` | So that nothing is left behind after removal. The Claude app deletes only on delete |
| Turning it on and off | Settings › General "Keep cookies": "Per task" (default) / "Shared by all tasks" | A setting in the same place as the Claude app's "Keep cookies". "Until quit" was left out, because it would mean something different in Yardlet, whose host ends often |
| Sign-ins from another browser | The cookies of the sites the person chose from the page menu of the browser panel replace that site's cookies in the default profile and in the panel task's profile, and the tasks that follow those sites take them too | So that sites whose passkey exists only in another browser can be used in Yardlet (section 10) |
| Touch ID passkeys | The default profile's `webauthn.touchid.metadata_secret` is put into each new task profile | Chromium reads Touch ID passkey metadata per profile with this key. Without it, the passkeys would not show in each task |

## 4. Structure

- **CEF bridge:** It creates one request context per folder path (`cef_request_context_create_context`, which also
  stores session cookies) and keeps it while browsers or cookie copies use that folder. When the last one ends, it
  releases the context. A cookie copy reads all of the source's cookies (`visit_all_cookies`), asks the source again
  with each cookie's address (`visit_url_cookies`, which answers only unpartitioned cookies) and puts only the cookies
  in that answer into the target (`set_cookie`; a host-only cookie goes in with an empty domain, so it stays host-only).
  When done, it writes the target store to disk (`flush_store`) and then reports (section 8). There are at most 16
  browsers in total (the host limit) and 32 contexts.
- **Host:** It takes the `profile` (`key`, `seedFrom`) of the `open` command and opens the tab in
  `<root cache>/Task-<key>`. It accepts only keys in UUID form, so a key cannot point at another folder. Chromium reads
  disk profiles asynchronously, so the browser is created after that profile is ready
  (`on_request_context_initialized`). When the folder is new, it puts in the Touch ID key, opens the tab at about:blank,
  copies the starting cookies and then opens the requested address (navigation and DevTools messages that arrive while
  it waits for the profile or copies wait until it is done). The `copyCookies` command moves one site's cookies from
  one profile to another, and with `replace` first deletes the target's cookies of that site. The `importCookies` command
  replaces the chosen sites' cookies in one profile with cookies imported from another browser (section 10). When the
  `open` command's `profile` has `follow` (a list of sites) or `fill`, the tab opens at about:blank, takes those sites
  from the default profile in place of its own, fills in the sites it has no cookie of, and then opens the address. The
  `cookieDigest` command answers a sum of hashes of one profile's cookies of one site (section 11).
- **Yardlet:** `BrowserTaskProfiles` handles the task's key (the task ID; for a task that came from the new task screen,
  that screen's key), the source of the starting cookies (the parent task's folder if there is one, otherwise the
  default profile), the setting and cleanup. `BrowserHostClient` attaches the profile every time it opens a task's tab,
  reports when a tab moves to another task, and calls cleanup when the host ends. Cleanup runs only after the saved task
  list has been read in full. Chromium writes every profile it opens into `Local State` (`profile.info_cache`,
  `profile.profiles_order`, `variations_google_groups`) and does not remove them when the folder disappears, so cleanup
  also removes `Task-` names without a folder from there.
- **The person's sign-in:** `BrowserLoginFollow` finds sign-ins and passes the person's to the
  default profile and the tasks that follow the site; how it finds them and the rules are in section 11. The vault's
  watcher (submission of a form with a password field the person typed into, a one-time code field) runs with "Per
  task" even when the vault is off, and what it reports is used to find sign-ins too.

## 5. Costs and limits

- **Memory (measured by the isolation QA with 8 windowless tabs on the same page):** a profile per task costs about
  6 MiB per profile over the single default profile, most of it in the browser process (per-profile services). There is
  one renderer per tab either way. What grows a lot as tabs increase is the frame surfaces the tabs draw, which has
  nothing to do with isolation.
- **Limits:** At most 16 browsers in total (the host limit, 9 per task) and 32 profile contexts. One browser process
  handles them.
- New tasks receive only cookies. Sites that keep sign-in tokens in localStorage or IndexedDB need a new sign-in in a
  new task (with an "Always" vault item, the agent does it).
- Partitioned cookies (CHIPS: cookies that a page embedded in another site keeps only under that top-level site) are not
  moved. CEF's cookie manager does not take a partition key, so inserting one would make a cookie that every top-level
  site receives (section 8). In a new task, embedded widgets start as if seen for the first time.
- A moved cookie keeps, instead of the scheme and port of whatever set it, those of the address the copy used (https:443
  if Secure, otherwise http:80). CEF does not report the original values. CEF 154 does not bind cookies to schemes (QA
  `schemeBoundCookies: false`), so sending them makes no difference. The Claude app's copy uses the same addresses.
- Finding the person's sign-in (section 11) needs a moment that starts one (a password field, a one-time code field, a
  passkey window, a popup, leaving for another site). A sign-in without such a moment (a sign-in link opened outside
  Yardlet, for example) is not passed on.
- When an archived task is restored, that task's browser starts again with the default profile's cookies.
- Changing the setting leaves already open tabs as they are. Tabs opened after that follow it.

## 6. QA

`run-check.sh … --ui-fixture-browser-check-only=isolation` (`BrowserHostIsolationQA`) checks on a real CEF host: whether
a new task starts with the default profile's cookies; whether two tasks keep separate cookies and localStorage on the
same site; whether a task's sign-in does not leak into the default profile; whether a child task starts with the
parent's cookies; whether the person's sign-in reaches the default profile, the running tasks and the tasks started
after it; whether the Touch ID key
goes into a new profile; whether, after the host ends and starts again, a task's cookies (session cookies included) and
localStorage remain and it does not receive the starting cookies again; whether switching to "Shared by all tasks" uses
the default profile; whether the folders of tasks that no longer exist and their `Local State` records are deleted.
Whether cookies move in the shape Chromium stored them (section 8): whether the QA server's sign-in check across two
sites (`/cookie-check`, console 127.0.0.1 and account site localhost) is `ok` both in the default profile and in a new
task; whether Google-shaped cookies planted with DevTools in the default profile (a host-only cookie and a `__Host-`
cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned cookie under another
top-level site) go into a new task with the same domain and Secure flag, and the partitioned cookie does not become a
top-level cookie; whether, after a sign-in done again in a task is moved to the default profile, the account site
receives each name once with the new value (both in the default profile and in tasks after it). Adding
`--ui-fixture-isolation-cookies` runs only this check. The checks of the sign-ins tasks follow (section 11) run too,
and adding `--ui-fixture-isolation-follow` runs only those. Every check uses a new task and decides first which values it
will read (the cookie check first deletes cookies of the same name from earlier runs), so state that earlier QA left in
the same QA home does not matter. Each step measures the process tree's memory (adding `--ui-fixture-isolation-shared`
opens the same tabs in the single default profile and measures that). The full `run-check.sh` also checks that a profile
keeps its cookies across host restarts.

## 7. Where task profiles are stored

- **Folder:** `Browser/Task-<key>` directly under the root cache (host `TaskProfiles`, app `BrowserTaskProfiles`, saved
  file `Browser/TaskProfiles.json`). CEF 154 (Chrome bootstrap) opens a disk profile only when the request context's
  `cache_path` is the root cache or directly under it; any deeper path is logged as "Cannot create profile at path" and
  becomes an in-memory (OffTheRecord) profile, which loses all of a task's sign-ins when the host ends.
- **Opening:** disk profiles are read asynchronously, and `create_browser_sync` cannot create a browser in a context that
  has not been read yet (it returns NULL). The bridge therefore creates the browser after it receives
  `on_request_context_initialized` for that context, and the host treats tabs in between like tabs that copy the
  starting cookies.
- **`Local State`:** Chromium keeps a record for each disk profile it opened (about 400 bytes per profile) even after the
  folder is deleted. Cleanup removes the `Task-` names that have no folder (section 4).
- The isolation QA restarts the host and checks that a task's cookies and localStorage remain, and checks `Local State`
  (section 6).

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
  a domain cookie, and such copies stay in a profile until removed. So Yardlet cleans up once, just before it first
  starts the browser host (it cannot while the host has the cookie DB open). In the `Cookies` of the default profile and
  of the `Task-<UUID>` profiles, it deletes the domain cookies that a copy created (`source_type` 3, set through the
  cookie manager) when a host-only cookie with the same name, path and partition is there, whatever created the
  host-only one: the earlier copy never created host-only cookies, so the host-only side of such a pair has the site's
  shape. The site's own cookies (`source_type` 1 or 2), including pairs the site created itself, and copies with no pair
  remain. Only for DBs with something to delete, it first copies `Cookies` and `-journal` and `-wal` to
  `~/.Trash/Yardlet cookie backup <date time>/<profile>/`, and leaves a profile untouched if its backup fails. It deletes
  in a single transaction. When everything is done, it leaves `CookieCopyRepair.json` (the run time, the number deleted
  per profile and the round) in the root cache, so it does not run again until a later round (the current round is 3).
  If the host holds the DB (the PID in `SingletonLock` is alive), the DB cannot be read (a journal that needs a rollback
  and the like), or the backup or deletion fails, it leaves no record and runs again at the next start. The Trash is the
  one of `NSHomeDirectory()`, which follows the home a QA run sets (FileManager's Trash would be the person's). Those
  sites may need a new sign-in.
- **QA:** the cookie checks in section 6. The one-time cleanup is checked by `BrowserCookieCopyRepairTests` (DBs in a
  temporary folder): which cookies go and which stay, the backups in the Trash, the record, a record of an earlier round
  letting the current round run once, and running again when a host holds the profiles or the backup fails.

## 9. Never two shapes of one cookie

- **On the sending side:** the copy (`set_copied_cookies`) leaves out domain cookies that have a host-only cookie with
  the same host, name and path. A profile may still hold domain cookies an earlier copy made next to the site's
  host-only cookie; passing both on would recreate the pair in the receiving profile.
- **On the receiving side:** for each cookie, the copy first deletes the other shape (a domain cookie for a host-only
  one, a host-only cookie for a domain one). CEF has no call that deletes exactly one cookie, so it writes a cookie with
  the same name, domain and path that has already expired. Chromium deletes just that one cookie (`cookie_monster.cc`
  `DELETE_COOKIE_EXPIRED_OVERWRITE`, 154.0.8037.58 source).
- Importing sign-ins (section 10) and passing on the person's sign-ins (section 11) insert through the same path.
- **QA:** the last step of section 6 plants domain cookies of the earlier copy (`.accounts.example.com`
  `qa_signin=OLD`) in both the default profile and a task, and checks that the default profile and a task created after
  it send only one `qa_signin`, the new value.

## 10. Importing sign-ins from another browser

- **Background:** Sites that sign in only with passkeys cannot be signed in to in the Yardlet browser when the passkey
  exists only in another browser (iCloud Keychain, Whale, Chrome). Importing that browser's sign-in cookies lets Yardlet
  enter the site, and after one more Yardlet passkey is registered in the site's settings, Yardlet alone is enough from
  then on. This is ④, which "Aside and Ego compared" in [BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md) deferred.
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
  store to disk (`flush_store`) and replies. The targets are the default profile and the profile of the panel's task. A
  task profile whose folder does not exist yet is not touched (it receives the cookies from the default profile when its
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
  side also ends the other. An import is the person's sign-in, so the tasks that follow those sites take
  it from the default profile too (section 11).
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=import` (`BrowserHostLoginImportQA`). It creates a fake Whale
  folder in the QA home's Application Support (two profiles, cookies encrypted with a test password: a host-only cookie
  and a `__Host-` cookie on `accounts.example.com`, Secure and non-Secure cookies on `.example.com`, a partitioned
  cookie, an expired cookie, a `localhost` cookie, and a `www.other.test` cookie that will not be chosen) and passes
  that password in place of the keychain. It first plants the old copy's domain cookies and other cookies of the site in
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

## 11. Tasks follow the person's sign-ins

- **Rule (section 3):** only the sites a task signed in to itself (its agent's vault fill or typed sign-in) stay that
  task's; on every other site all tasks follow the person's latest sign-in. Normally, as in the Codex app, every task
  uses the same sign-ins, and only a task that went in with another account keeps its own. This rule lives within
  "Per task" of Settings › General "Keep cookies"; "Shared by all tasks" uses one profile for every task.
- **Finding sign-ins (`BrowserLoginFollow`):** A cookie change alone cannot tell a sign-in from a site renewing its
  cookies (Google renews them all the time while in use). So only when a moment that starts a sign-in occurs does it
  measure a sum of hashes of that site's cookies (the FNV-1a of name, domain, path and value, added up; the host
  computes it and no value leaves the host), and a different value measured again within three minutes is a sign-in.
  - Moments: the page's password field takes focus (the host's `passwordField`), a one-time code field shows on a
    panel's page (the vault's watcher), Chromium's passkey window opens over the tab (the host says which tab each window
    is over: [BROWSER_HOST](BROWSER_HOST.md) section 3, "Chromium's windows and tabs"; a window whose tab is not known is
    left out), the page opens a popup (a "Sign in with Google" window), the tab leaves the site for another (a single
    sign-on round trip).
  - When it measures again: when the tab has loaded a page of that site, when it leaves the site, 2 and 8 seconds after
    a popup or passkey window closes, 4 and 12 seconds after the panel's sign-in form is submitted. Within the three
    minutes it also catches the cookies set after two-step verification.
  - Whose sign-in: whoever used the tab last when it measures again. The person's when the person used the tab in the
    last three minutes and the agent has not used it since (`BrowserTab.isDrivenByAgent`), on a page the agent handed
    over (`browser_handoff`) too. A popup that has closed goes by who used the tab that opened it when the sign-in
    began. A sign-in the agent made through a password or code
    field and a vault fill (`.vaultFilled`) are the task's own. When the agent's moment is not a password or code field
    (browsing), it is nothing, and so is a tab nobody drives that goes through another site on its own.
- **Passing it on:** For the person's sign-in it counts the site's sign-in number up by one and copies that task
  profile's cookies of the site to the default profile and to the tasks with tabs open now that follow the site. The
  target's cookies of the site go first (the same visitor as the import in section 10): when two sessions' cookies mix
  on one site, Google's accounts site blocks it with `/CookieMismatch` (sections 8 and 9). Insertion is the path of
  sections 8 and 9 (`set_copied_cookies`) as it is, so host-only pairs and deleting the other shape (writing it expired)
  hold. A task without an open tab takes the site's cookies from the default profile at about:blank when its tab next
  opens, then opens the address (`BrowserTaskProfiles.opening`, `follow` in the host's `open`). A sign-in imported from
  another browser (section 10) is the person's too, so it goes from the default profile to the same tasks.
- **A task's own sign-in:** That site of that task leaves following, and a sign-in the person makes again in that task
  is not passed to others (whether the task's account is the person's cannot be known, so the side that overwrites
  nothing). A child task inherits its parent's own sign-ins. When the feature turns on, it reads the agents' fills in the
  vault's usage log (`~/.yardlet/vault/usage.jsonl`, 90 days) once and takes each as that task's own sign-in on that
  site.
- **First run:** A task made before the feature, the first time its tab opens afterwards, fills in from the default
  profile only the sites it has no cookie of at all (`fill`). Sites that already have cookies stay as they are; what
  overwrites them starts with the person's sign-ins made after the feature turned on. The bridge has no public suffix
  list, so a fill's site is coarser than the registrable domain (an IP address whole, otherwise the host's last two
  labels). Coarser only fills less; it never overwrites.
- **Storage:** `following` in `Browser/TaskProfiles.json`: each site's sign-in number of the person (`signIns`), per
  profile key the numbers it took (`received`) and its own sign-ins (`own`), the keys that began following
  (`followers`), and whether the vault log was read. No cookie values. The records of archived and deleted tasks go with
  their folders.
- **Where:** `BrowserLoginFollow.swift`, `BrowserTaskProfiles.swift` (`opening`, `personSignedIn`,
  `signedInItself`), `BrowserHostClient.swift` (`cookieDigest`, `copyCookies(from:to:site:)`, the tab event hook),
  `BrowserHostProtocol.swift`, `BrowserHostPaneVault.swift` and `BrowserHostPaneLoginImport.swift` (moments and
  imports), `VaultCenter.swift` (`agentFills`), the host's `BrowserHost.swift` and `TaskProfiles.swift` (the list of
  copies, `cookieDigest`), and in the bridge `yardlet_cef_copy_cookies` (a list of sites; add, replace or fill) and
  `yardlet_cef_cookie_digest`.
- **QA:** `run-check.sh … --ui-fixture-browser-check-only=isolation` (only these with `--ui-fixture-isolation-follow`).
  The QA server's `/follow/signin` (localhost) has a password form and a "Sign in with QA" link that goes through an
  account picker on another site (127.0.0.1) and back; both plant `qa_follow`. The person clicks through the host's
  input (the panel's path); the agent acts through DevTools and reports its use. Seven checks: the agent's password
  sign-in is its task's own (the person's sign-in number unchanged, open task F does not get it); the person's password
  sign-in reaches open task F and the default profile, and the agent's task G keeps `AGENT`; cookies a site renews while
  the person browses are not passed on; a single sign-on round trip in a tab nobody drives is not passed on; the
  person's sign-in without a password (single sign-on) reaches F and a task made later, and G keeps its own; the person's password sign-in on a page the agent handed over
  reaches F and the default profile and does not become that task's own; a task from
  before following keeps its own cookie on 127.0.0.1 (`OLD`) and takes only the site it had no cookie of
  (`fill.qa-follow.test`). The host log has command names only, no cookie values. The moments the QA goes through are
  the password field and the round trip through another site. The popup, passkey window and code field moments use the
  same comparison but are not run in QA (the passkey window could take the screen).
- **Limits:**
  - A sign-in the person makes on a page the agent handed over is the person's even with an account for that task alone
    (someone else's account, for example), so it spreads to other tasks. Such an account stays in its task when the
    agent fills it from the vault.
  - A task-only sign-in from before the feature with no vault record has no mark, so when the person later signs in to
    the same site, that task follows too.
  - A sign-in without a moment (a sign-in link opened outside Yardlet, for example) is not passed on. A passkey request
    the agent started and the person answered with Touch ID is no one's sign-in (the agent's moment is not a password or
    code field).
  - If the site changes its cookies by itself within three minutes after a moment, that is passed on once too (the
    window kept to catch two-step verification).
  - When passing a sign-in on, the target's partitioned cookies of the site are deleted too and do not come back
    (section 5: partitioned cookies cannot be moved). localStorage and IndexedDB do not follow.
  - A sign-out that ends within the site is not passed on (no moment). A sign-out that goes through another site
    (single sign-on sign-out) is passed on like a sign-in, so the tasks that follow the site are signed out too. When
    the person then signs in with another account, that sign-in is passed on.
