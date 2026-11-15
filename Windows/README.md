# Windows

What the Windows app is built from besides its sources in `Sources/NativeHarnessClient/WinUI/` and
`Sources/NativeHarnessClient/Platform/Windows/` (docs/PLATFORM_PORTABILITY.md, "The Windows app"):

| Path | What it is |
| --- | --- |
| `Bindings/projections.json` | The WinUI types the app uses, and the Microsoft packages, with their SHA-512 hashes, their bindings are generated from |
| `Bindings/swift-winrt.json`, `Bindings/swift-winrt-patches/` | The swift-winrt commit that generates the bindings, and the fixes applied on it until swift-winrt has them |
| `Bindings/Package.swift`, `Bindings/Sources/` | The bindings as Swift modules linked into the app, the bootstrapper's link, and `XamlApplication`, the application type the app derives from |
| `scripts/generate-bindings.ps1` | Builds swift-winrt, restores the packages and generates the bindings into `Bindings/Generated/`, which git ignores |
| `scripts/place-bootstrapper.ps1` | Puts the Windows App SDK's bootstrapper beside the app's executable, and the Windows App Runtime's x64 packages the app puts in place in `WindowsAppRuntime` |
| `scripts/test-swift-winrt.ps1` | Builds swift-winrt with the patches and runs its own tests, as its CI does (`.github/workflows/swift-winrt-tests.yml`) |
| `scripts/check-window.ps1` | Opens a build, measures its memory, idle processor time and what it loads, types Korean into its composer through the Microsoft Korean IME, and checks that Shift+Enter starts a new line |
| `scripts/start-remote-host.ps1`, `scripts/check-remote.ps1` | Start the relay and, when given one, the fixture host on it, and pair a build with that host, open a task, send a message and wait for the answer to stream in |
| `scripts/place-relay.ps1` | Puts the relay a build carries beside its executable, from `YARDLET_RELAY_URL` or Packaging/RelayURL, as `scripts/build-app.sh` puts the Mac's in Info.plist |
| `scripts/check-remote-host.ps1` | Turns on Settings › Remote in a build, pairs the fixture as a phone over the build's direct listener and as another through the relay with the links it copies, has each phone's message answered, checks that the listener refuses a browser's handshake and a text frame, and checks the device list and that turning the remote off closes the listener and the relay room |
| `scripts/check-local.ps1` | Starts a task in a build with the stand-in harness `check-harness.ps1` installed, allows its request, waits for its answer, and opens the build again to find the answer kept |
| `scripts/check-import.ps1` | Imports a conversation the stand-in saved for a folder chosen in Windows' folder dialog through Import conversation, checks that the stand-in was asked for the folder as Windows writes it, and finds the conversation drawn with its task's row chosen |
| `scripts/check-harness.ps1`, `scripts/fake-harness/` | Install a stand-in ACP harness with npm, let a build find it, start it through npm's shim and stop it, and check that a process the stand-in started ended with it |
| `scripts/check-codex.ps1` | Installs the Codex CLI with npm, lets a build start its App Server in the environment a task gives it, and checks that the build named Codex's home as Windows writes it, made it where Codex never ran, and had `initialize` and `thread/list` answered without a sign-in |
| `scripts/pack.ps1`, `scripts/set-app-icon.ps1` | Pack a build with Velopack into the per-user installer, the portable zip and the update feed, with Yardlet's icon set into the executable, Velopack's library and the feed beside it, signed when given a certificate's signtool arguments or a signing command; it packs a build folder or the app a run gathered, on a computer without Swift (docs/PLATFORM_PORTABILITY.md, "Installing and updating the Windows app") |
| `scripts/check-install.ps1` | Takes the Windows App Runtime's packages from the runner's user, packs a build as two versions, installs the first without a window, updates it from a feed in a folder to the second, signed with a certificate made for the check, and removes it, checking that the install hook put the runtime in place, the hooks, the icon, the shortcut, the Apps entry and that the app's data stays as it was |
| `scripts/install-swift.ps1`, `scripts/install-windows-app-runtime.ps1`, `scripts/report.ps1` | The CI runner's Swift and Windows App Runtime, and a run's annotations |
