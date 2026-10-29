# Yardlet

[![CI](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/zzunkie/yardlet/actions/workflows/ci.yml)

<a href="https://www.producthunt.com/products/yardlet-2"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1294326&theme=dark">
  <img alt="Yardlet, featured on Product Hunt" src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1294326&theme=light" width="200">
</picture></a>

A native macOS app for running coding agents. Codex, Claude Code and other agent CLIs open side by
side in one window of projects and tasks, while each agent keeps its own agent loop, sign-in and
session history.

Yardlet is written in Swift and SwiftUI; it is not a web view. It does not replace the agents or
proxy their accounts: it starts the CLI you already use, with the account you already signed in to.

Most of us will end up with an agent workbench of our own. Yardlet began as one, built for working with
several agents and accounts every day, and it is shared for anyone who doesn't have one yet.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/main-dark.png">
  <img alt="A Codex task in Yardlet: the conversation, with the changes, pull request checks, progress and settings beside it" src="docs/images/main-light.png">
</picture>

## What it does

- **One window for every agent.** Codex, Claude Code, OpenCode, Cursor Agent, Antigravity CLI,
  Kimi Code, Grok Build, Pi and others share the same sidebar, conversation view, composer and
  approval cards. Controls stay in the same place; the choices and values come from each agent.
- **Sessions stay where the agent keeps them.** Codex runs against your normal `CODEX_HOME` and
  Claude Code against its own store, so a session started in Yardlet resumes in the original app or
  CLI, and the other way round. Yardlet keeps only its own index, drafts and reading state.
- **Stop whenever you like.** Yardlet writes nothing into the agents' own configuration; it hands
  them its tools when it starts them. Quit it or remove it, and each agent, its sign-in and its
  sessions are as they were, ready in the original app or CLI (see [Uninstall](#uninstall)).
- **Several accounts.** Register more than one account per provider and start a task on the one
  with quota left; Yardlet shows each account's session and weekly limits.
- **Review the work.** Diffs of the last turn, file restore and fork, a pull request tab with checks
  through your own `gh`, a terminal, and a files pane next to the conversation.
- **Connectors for every agent.** Gmail, Google Calendar and Google Drive through Yardlet's
  built-in MCP server on your Mac, GitHub, Slack, and dozens of remote MCP services that connect
  with one sign-in. A connector set up once is offered to the agents you run, and can be turned off
  per task.
- **Built-in browser.** A Chromium panel the agents can drive through browser tools while you watch.
- **Personal agents.** Chat with your existing ChatGPT dots alongside coding tasks, with saved drafts
  and native file previews. The account stays with its Codex runtime; no browser needs to stay open
  (see [Personal agents](docs/PERSONAL_AGENTS.md) for current limits).
- **Scheduled tasks** that run while Yardlet is open, and session tools that let one task read,
  message or start another.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/review-dark.png">
  <img alt="Reviewing a task's changes: the diff of a file opens in a pane next to the conversation" src="docs/images/review-light.png">
</picture>

## Requirements

- macOS 15 or later on Apple silicon.
- At least one agent CLI installed and signed in, for example `codex` or `claude`. Yardlet uses the
  CLI's own sign-in and never copies it from other apps.

## Install

Download the notarized `Yardlet-<version>.dmg` from [Releases](../../releases), open it and drag
Yardlet to Applications. Or install it with [Homebrew](https://github.com/zzunkie/homebrew-tap):

```sh
brew install --cask zzunkie/tap/yardlet
```

Either way, Yardlet then updates itself (see [Updates](#updates)).

The `main` branch can be ahead of the latest release, so a feature described in this repository may
not be in the app you installed yet. **Yardlet > About Yardlet** shows the installed version, and
[Releases](../../releases) lists what each version contains.

To build from source, see [Development](#development).

### Updates

Yardlet updates itself with [Sparkle](https://sparkle-project.org). Once a day it reads
`https://yardlet.app/appcast.xml`; a newer version downloads in the background and is installed when
Yardlet quits. **Yardlet > Check for Updates…** checks now and offers **Install and Relaunch**. With
tasks running, Yardlet waits for them to finish before it quits to update; meanwhile the Yardlet menu
shows **Waiting to Update**, and **Cancel Update** leaves the update for the next quit.
Turn off **Settings > General > Automatically check for updates** and Yardlet asks for nothing until
you check yourself.

An update installs only if it is signed with the release key built into Yardlet and with the same
Developer ID. Sparkle keeps its settings in Yardlet's own preferences (keys starting with `SU`) and
downloads under `~/Library/Caches/com.zzunkie.yardlet/org.sparkle-project.Sparkle/`. It installs no
login item, launch agent or system helper: its installer runs only while an update is put in place.

### Uninstall

Quit Yardlet and move it to the Trash, or run `brew uninstall --cask zzunkie/tap/yardlet`. Your
agents, their sign-ins and their sessions do not change. If **Settings > General > Keep tasks
working with the lid closed** is on, turn it off first: macOS keeps an app's background item after
the app is deleted. It has nothing left to run then, and you can also turn Yardlet off in **System
Settings > General > Login Items & Extensions**. To remove Yardlet's own data as well:

- `~/.yardlet` (task list, drafts, reading state) and `~/Library/Application Support/Yardlet`
  (browser profiles, staged updates). `brew uninstall --zap --cask zzunkie/tap/yardlet` removes
  these together with Yardlet's caches and preferences.
- In Keychain Access, the items whose name starts with `Yardlet` (connector sign-ins, the phone
  remote, the password vault), and `Chromium Safe Storage` if you do not use Chromium itself.
- Yardlet's entries in **System Settings > Privacy & Security**.

## Privacy

Yardlet has no analytics and no server that receives your work. Task metadata, drafts and reading
caches live under `~/.yardlet`; agent sessions stay in each agent's own store. If you pair a phone
with the phone remote and it is away from your network, its end-to-end encrypted messages pass
through Yardlet's relay at `relay.yardlet.app`, which cannot read them and stores none
([relay/README.md](relay/README.md)). Connector sign-ins are kept in the
macOS Keychain, and connector calls go straight from your Mac to the service. What an agent reads
through a connector is sent to that agent's provider under your account with it. The daily update
check asks `yardlet.app` for the appcast with Yardlet's and Sparkle's versions in its user agent and
sends no system profile; updates download from GitHub Releases. See the
[privacy policy](https://yardlet.app/privacy.html).

## Roadmap and feedback

What's being worked on and what comes next is on the [roadmap](https://github.com/users/zzunkie/projects/1),
and each release gathers its work in a [milestone](https://github.com/zzunkie/yardlet/milestones).
Report bugs and ideas in [issues](https://github.com/zzunkie/yardlet/issues/new/choose), ask questions in
[Discussions](https://github.com/zzunkie/yardlet/discussions), and see [CONTRIBUTING.md](CONTRIBUTING.md)
to send a pull request.

## License

[MIT](LICENSE). Bundled third-party software and marks are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Product names and logos of the supported agents
belong to their owners; Yardlet is not affiliated with or endorsed by them.

## Development

Building needs Xcode 27.1 or later (Swift 6.4); Xcode 26 cannot compile Yardlet.

```bash
swift build --build-system native
./scripts/test-fast.sh
swift run --build-system native NativeHarnessClient
```

The default build system also compiles SwiftTerm's Metal shaders and stops when the Metal toolchain
is not installed; `--build-system native` builds without it. `scripts/test-fast.sh` runs every test
except renders, QA fixtures and performance runs, as CI does for each pull request;
`swift test --build-system native` runs them all.

For a normal registered macOS application bundle during development:

```bash
./scripts/build-app.sh
open .build/Yardlet.app
```

To update the installed app from inside Yardlet (for example, from a Yardlet task that works on
Yardlet itself), build a release bundle and stage it, then choose **Yardlet > Install Update…**. A
bundle built without Sparkle's feed and key (see [Releases](#releases)) has this item instead of
Check for Updates…, and makes no update request:

```bash
./scripts/build-app.sh release && ./scripts/stage-update.sh
```

Staging verifies the bundle and copies it to `~/Library/Application Support/Yardlet/Updates/Pending`;
it never touches the installed app. Install Update… asks for confirmation, quits Yardlet through the
normal quit path (which warns about running tasks), and a detached installer swaps the bundle once the
app has exited, keeps the previous one in `Updates/Previous`, and reopens Yardlet. Tasks, drafts and
history live outside the bundle. The installer log is `Updates/install.log`. While tasks run, Install Update…
also offers **Restart When Tasks Finish**: Yardlet waits until no task has run for a few seconds, checks that the
staged build is still the one chosen, and installs through the same quit; the Yardlet menu shows the wait and
**Cancel Update** ends it.

Yardlet shows a staged build without being asked, as the Claude app shows a downloaded update: **Restart to
update** above the account button at the bottom of the sidebar, and the same line above Quit in the menu bar
menu, both opening Install Update…. It looks when the window opens, when Yardlet comes to the front and once
a minute, and only checks that the staged build is Yardlet's and not the one installed; the signature is
checked when you install. A build that updates with Sparkle does not look.

The bundle script uses SwiftPM's native build engine to retain its established resource layout.
On toolchains that default to Swift Build, use `swift test --build-system native` for the same
pipeline. Set `YARDLET_BUILD_SYSTEM` to override the engine used by the bundle script.

For small changes, `./scripts/test-fast.sh` runs every test except the windowless renders, QA
fixtures and performance runs, in four parallel processes (about 5 minutes; the whole suite takes
about 15 minutes serially). Run the whole suite before a release.

Bundles include the in-window browser (Chromium Embedded Framework in a separate browser host
process). The script uses the pinned CEF distribution in `~/Library/Caches/Yardlet/CEF/`, verifies
its hash, and stops with the download command when it is missing. A debug bundle can be built without
it with `YARDLET_WITHOUT_CEF=1`; `swift build`, `swift run`, and `swift test` never need CEF and fall
back to the WebKit preview. See [docs/BROWSER_HOST.md](docs/BROWSER_HOST.md).

### Screenshots and demo videos

Debug builds carry a showcase scene for public screenshots and videos: made-up projects, people and
accounts, in English, with Codex, Claude Code and OpenCode tasks, a pull request whose checks
passed, and a turn that can play over and over for recording (`--ui-fixture=showcase`, optionally
with `--ui-fixture-playback`). `scripts/showcase/capture.sh <folder>` takes the stills and the
looping videos in light and dark mode from a QA copy of `.build/Yardlet.app` with its own bundle
identifier and temporary home, then moves that copy to the Trash. It needs the screen unlocked and
the Screen Recording permission; see the script's header for the scenes and file names.

### Signing and notarization

The macOS build resolves SQLite through the SDK and links `/usr/lib/libsqlite3.dylib`, keeping
Developer ID library validation independent of local Homebrew packages.

`build-app.sh` signs ad-hoc by default, as before. To sign with an identity from the keychain
(hardened runtime, each part's entitlements from `Packaging/Entitlements`, inside out through
`scripts/sign-app.sh`), then notarize:

```bash
YARDLET_SIGNING_IDENTITY="Developer ID Application: <name> (<team>)" ./scripts/build-app.sh release
./scripts/notarize.sh --dry-run   # local checks only; nothing is sent
./scripts/notarize.sh             # submit, wait, staple: the app, then .build/Yardlet-<version>.dmg
```

- Once per Mac, store the notary credentials in Terminal; notarytool asks for an app-specific
  password (appleid.apple.com > Sign-In and Security) and keeps it in the login keychain. The scripts
  never handle a password:
  `xcrun notarytool store-credentials yardlet-notary --apple-id <Apple ID email> --team-id <team>`.
  Another profile name goes in `--keychain-profile <name>` or `YARDLET_NOTARY_PROFILE`.
- `notarize.sh` first checks every Mach-O for Developer ID, a secure timestamp, the hardened runtime
  and no `get-task-allow`, and that the profile exists. It submits the app as a zip and staples it,
  puts the stapled app beside a link to /Applications in a disk image (`--output <file.dmg>`), signs
  the image with the app's certificate, submits and staples it, and runs `spctl` on both.
- Entitlements: the Renderer and GPU helpers `cs.allow-jit` (as Chrome's); the browser host Bluetooth
  and USB for passkeys; the app Bluetooth for the host it launches, and Apple Events, microphone and
  camera for the commands it runs (harnesses, their tools, the terminal), which macOS attributes to
  Yardlet; each has its usage string in `Info.plist`.
- The lid helper behind Settings › General › "Keep tasks working with the lid closed"
  (`Contents/Helpers/yardlet-lid-helper`, with its launchd property list in
  `Contents/Library/LaunchDaemons`) is signed with its label, `<app identifier>.lid-helper`, as its
  identifier. The app and the helper accept each other only when signed by the same team, and the
  property list's launch constraint (`SpawnConstraint`), whose team `sign-app.sh` fills in, lets
  launchd start no other executable as root. A build signed ad hoc has no team, so it carries no
  property list and offers no helper.
- A Developer ID identity signs with a secure timestamp (Apple's timestamp server); other identities,
  such as Apple Development for local checks, sign without one unless `YARDLET_SIGNING_TIMESTAMP=1`.
  Only a Developer ID build can be notarized.
- `YARDLET_PROVISIONING_PROFILE=<path>` embeds a Developer ID profile in the browser host
  (`Yardlet Browser Host.app/Contents/embedded.provisionprofile`) with the entitlements it grants. The
  profile must be for the App ID `<team>.com.zzunkie.yardlet.browser-host`; the app itself needs none.
  Touch ID passkeys stay off with the stock CEF build, whose keychain group has no team ID
  (`YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1` enables the tested opt-in prototype; see docs/BROWSER_HOST.md §7).
- A Developer ID build keeps the browser's cookie key in the login keychain instead of the mock
  keychain, so sites in the built-in browser need signing in again once after the switch.
- Once the installed app is Developer ID signed, `stage-update.sh` and Install Update… accept only a
  build that meets its designated requirement (same identifier, same team). Build updates with the
  same identity.
- `sign-app.sh` signs Sparkle's framework from the inside out with the same identity, hardened
  runtime and timestamp (its XPC services, `Autoupdate`, `Updater.app`, then the framework), as
  Sparkle documents for Developer ID; the notarization check covers them like every other Mach-O.

### Releases

`scripts/release.sh` prepares a release and publishes nothing:

```bash
YARDLET_SIGNING_IDENTITY="Developer ID Application: <name> (<team>)" ./scripts/release.sh \
  --appcast <yardlet-site checkout>/appcast.xml --notes notes.md
```

It builds the release bundle with Sparkle's feed (`YARDLET_SPARKLE_FEED_URL`, default
`https://yardlet.app/appcast.xml`) and public key, notarizes the app and `Yardlet-<version>.dmg` with
`notarize.sh`, and runs Sparkle's `generate_appcast`, which signs the image with the EdDSA key and
writes `appcast.xml` with the download under the GitHub release `v<version>`. It checks that the key
built into the app accepts that signature, then prints the publishing steps: the GitHub release
first, then the appcast on the site. Everything lands in `.build/release-<version>/`.

- Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Packaging/Info.plist` and commit
  first: Sparkle orders updates by `CFBundleVersion`.
- The EdDSA key, once per maintainer: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account yardlet`
  makes the private key in the login keychain and prints the public key, which `release.sh` reads back
  with `generate_keys --account yardlet -p` (or set `YARDLET_SPARKLE_PUBLIC_KEY`; another account name
  goes in `YARDLET_SPARKLE_ACCOUNT`). Export one copy with `generate_keys --account yardlet -x <file>`
  and keep it offline, never in the repository. Without the key, installed
  copies take an update only through Sparkle's key rotation: a new key, and the same Developer ID.
- `build-app.sh` writes `SUFeedURL` and `SUPublicEDKey` only when both `YARDLET_SPARKLE_FEED_URL`
  and `YARDLET_SPARKLE_PUBLIC_KEY` are set; QA copies made by `prepare-qa.sh` drop them.
- `--skip-notarize` tries the steps locally with an image that must not be published, and
  `--ed-key-file <file>` signs with a key file instead of the keychain.

For Touch ID QA, register the explicit App ID `com.zzunkie.yardlet.browser-host` under the signing
team and create its **Developer ID** provisioning profile using the existing Developer ID
Application certificate. Store the downloaded profile outside the checkout, for example under
`~/Library/Developer/Yardlet/`; never commit it. Its team and
`com.apple.application-identifier` must match the signing identity and host, its expiration must
be in the future, and `ProvisionsAllDevices` must be true. The profile must grant the keychain
groups used by the patched CEF build (`<team>.com.zzunkie.webauthn` and `…webauthn-uvk`, usually
through `<team>.*`). The current Developer portal has no separate Keychain Sharing checkbox;
verify the generated profile rather than enabling unrelated capabilities. See Apple's [keychain sharing documentation](https://developer.apple.com/documentation/xcode/configuring-keychain-sharing).

Build in a separate worktree, then prepare a QA copy with the same signing variables:

```bash
export YARDLET_SIGNING_IDENTITY="Developer ID Application: <name> (<team>)"
export YARDLET_PROVISIONING_PROFILE="$HOME/Library/Developer/Yardlet/Yardlet_Browser_Host_Developer_ID.provisionprofile"
export YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1
nice -n 10 ./scripts/build-app.sh debug
nice -n 10 ./scripts/browser-host-qa/prepare-qa.sh .build/Yardlet.app \
  .build/browser-host-qa/YardletPasskeyQA.app com.zzunkie.yardletqa.passkey
./scripts/browser-host-qa/qa-launch.sh .build/browser-host-qa/YardletPasskeyQA.app \
  "$PWD/.build/browser-host-qa/qa-home" "$PWD/.build/browser-host-qa/app.log" -- \
  --ui-fixture=conversation --ui-fixture-surface=browser --ui-fixture-browser-ignore-occlusion
```

When a profile is supplied, `prepare-qa.sh` preserves the browser host's original App ID so the
profile remains valid; the outer app and helpers still use QA identifiers. Launch through
`qa-launch.sh` with a separate QA home and the conversation fixture. The cookie keychain stays
mocked, but Touch ID QA uses the real keychain access groups and requires the person to authenticate.
On a public test site such as `webauthn.io`, confirm both registration and authentication with the
platform authenticator. A valid signature or an available authenticator alone does not establish
that either ceremony succeeded. Both ceremonies were verified with Touch ID on 2026-10-23.
This does not enable iCloud Keychain passkeys (docs/BROWSER_HOST.md §7).

Runtime paths are selected per session and the local index is restored without eagerly starting either harness.

Yardlet-owned task metadata, drafts, and reading caches live under `~/.yardlet`.
New tasks use each harness's original session store. Codex runs against the native
`CODEX_HOME` (normally `~/.codex`), so the same provider session ID can be resumed
from Yardlet or the original Codex client. The Account Center uses that same home;
Yardlet does not copy credentials, settings, or session history into another home.

Previously created isolated Codex tasks retain their saved scope and continue to
resume and fork under `~/.yardlet/harnesses/codex/home`. They are not moved or silently
rebound to a different session. Native history imports retain their original IDs;
Yardlet's sidebar index and local UI state remain separate from provider storage.
See [native session storage](docs/NATIVE_SESSION_STORAGE.md) for verification and scope.

Additional provider accounts can be registered under Connections → Accounts.
Choose an account for a new task by its available quota; saved tasks retain their selected CLI
environment.
See [provider connections](docs/PROVIDER_CONNECTIONS.md) for the supported boundaries.

Claude uses the selected official CLI's own authentication. If `claude auth status`
reports `loggedIn: false`, run `claude auth login`; the client does not import Claude
Desktop credentials or provider tokens. When no explicit Claude runtime has been saved,
the client prefers the newest executable CLI bundled with Claude Desktop before an older
PATH binary; the exact path remains visible and selectable in the new-session sheet.
