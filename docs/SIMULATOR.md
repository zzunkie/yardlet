# Simulators in the side panel

A task's side panel can hold a Simulator tab: an iOS simulator's, an Android emulator's or an Android device's
screen, live, which the person uses with the mouse, the trackpad and the keyboard as on the device. Yardlet runs the
simulators of the person's own Xcode without opening Simulator.app, and the emulators of the person's own Android SDK
without a window, shows the Android phones and tablets that SDK's adb reaches, and changes nothing in Xcode's or the
SDK's settings or their lists of devices.

The code:

- `Sources/NativeHarnessClient/Simulator/`: the devices, which task attaches and claims each, and the devices
  Yardlet started (`SimulatorCenter`); the Settings switch (`SimulatorPreference`); the device menu's items
  (`SimulatorDeviceMenu`).
- `Sources/NativeHarnessClient/Simulator/Android/`: the Android SDK, its emulators and the devices adb reaches
  (`AndroidEmulatorBackend`),
  and the client side of the scrcpy server's protocol (`ScrcpySession`).
- `Sources/NativeHarnessClient/Platform/macOS/Simulator/`: the iOS simulators through `simctl`
  (`MacIOSSimulatorBackend`), the simulator host's process and protocol client, the Android screens' streams and
  decoding (`AndroidScreenClient`, `AndroidVideoDecoder`), the panels' screens (`MacSimulatorScreens`), the tab
  (`SimulatorPane`) and the screen view with the person's input (`SimulatorScreenView`).
- `Sources/YardletSimulatorHost/`: the simulator host, a helper executable in the bundle that opens Xcode's
  SimulatorKit at run time.
- The agents' tools: their definitions (`Sources/YardletAgentTools/SimulatorToolCatalog.swift`), their checks and
  results (`Sources/NativeHarnessClient/AgentTools/SimulatorAgentTools.swift`), the person's approvals
  (`SimulatorApprovals`), and the iOS simulators' screenshots and input (`MacIOSSimulatorDriver`).

## Turning it on and off

Settings › General › Simulator turns the feature on and off. It is on by default, and Yardlet's Mac app is the
only one that offers it. An agent that changes it through Yardlet's settings tools asks the person every time.

- On: once the saved tasks are read at launch, Yardlet checks this Mac's Xcode and Android SDK off the main
  thread and lists the devices. Simulator is offered in the side panel's launcher and + menu.
- Off: Simulator leaves the launcher and the + menu, open Simulator tabs close, the simulator host ends, and
  the devices Yardlet started shut down, a download stops, and Yardlet asks whether to remove what it installed
  ("Removing what Yardlet installed"). Nothing runs while it is off: no command and no file.

Simulator stands in the launcher and the + menu after Browser: Review, Terminal, Browser, Simulator, Files,
Side chat in a task with a repository; Files, Side chat, Browser, Simulator, Terminal in one without. The new
task screen does not offer it, since a device belongs to a task. There is no title bar button or shortcut of its
own: the side panel's button and ⌥⌘B come back to the tab used last, Simulator included. The tab's title is the
attached device's name, and its icon a phone.

## What it needs

iOS simulators need a full Xcode: the one `xcode-select` names when it is a full Xcode, else the newest
`/Applications/Xcode*.app`. Yardlet never changes `xcode-select`. That Xcode's first launch must be done
(`xcodebuild -checkFirstLaunchStatus`), CoreSimulator must be installed, and an iOS runtime must be available.
Yardlet runs `simctl` only after the first launch check, since Xcode's `simctl` would otherwise start the first
launch's installation itself.

When something is missing, the tab says what and what to do about it:

| Missing | The tab says |
|---|---|
| Xcode | Xcode isn't installed. Install Xcode from the App Store to use iOS simulators here. |
| Xcode's first launch or CoreSimulator | Xcode isn't set up yet. Open Xcode once and finish its setup, which asks for an administrator password, then come back. |
| An iOS runtime | No iOS simulator runtime. Add an iOS runtime in Xcode › Settings › Components. |
| Support for this Xcode in the simulator host | This Xcode isn't supported yet. Yardlet can't show simulator screens with Xcode 27.2 yet. |
| The Android SDK | No Android SDK. Install Android Studio and create a virtual device in its Device Manager to use Android emulators here. |

Android emulators need the Android SDK with its `emulator` and `platform-tools` (adb): the folder `ANDROID_HOME`
or `ANDROID_SDK_ROOT` names, the one whose tools are on the login shell's `PATH`, or `~/Library/Android/sdk`, where
Android Studio puts it. The emulators are the AVDs in the SDK's AVD folder, which Android Studio's Device Manager
makes.

Android devices are the phones and tablets that SDK's adb lists ready: over USB once the device allowed this Mac's
USB debugging, or over the network once the person connected it with `adb connect` (across Tailscale, for one) or
paired it in Android Studio. One that has not allowed this Mac yet, or does not answer, is not listed. Yardlet asks a
device, once each time it connects, for the serial number it reports (`getprop ro.serialno`), its model, its Android
version and the name the person gave it in its settings (`settings get global device_name`), and knows it by that
serial number, never by adb's serial, which a wireless connection changes and another device can take. Yardlet does
not connect, pair, turn on or turn off a device.

The tab lists the devices of each platform that can run here and says nothing of the other; only when neither
can does it say what each one needs, one under the other. Simulator stays in the launcher and the + menu either
way; the switch is the way to hide it. A saved Simulator tab whose device is attached while Xcode or the Android
SDK is gone says only "Xcode can't be found." or "The Android SDK can't be found.", with Close.
Where Yardlet can get what is missing, the tab offers it (below).

The check runs when the switch turns on and each time a Simulator tab appears; the tab also reads the devices
again then. Nothing reads them on a timer.

## Installing what is missing

Where Yardlet can get a missing part, the tab offers it under what is missing. Nothing downloads until the person
accepts what the tab shows; Cancel stops a download, and a failed one says why with Try Again.

- **No Xcode:** Open App Store opens Xcode's page in the App Store (`macappstore://apps.apple.com/app/xcode/id497799835`),
  where the person installs it. Yardlet does not install Xcode.
- **Xcode not set up:** the person opens Xcode once; its first launch installs CoreSimulator and asks for an
  administrator password, which Yardlet does not ask for.
- **No iOS runtime:** Install shows the runtime and its size, then Download runs Xcode's own
  `xcodebuild -downloadPlatform iOS` (with `-architectureVariant arm64` on Apple silicon), showing the percentage it
  prints. The size comes from Apple's public list of simulator runtimes
  (`devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex`): the runtime build it maps the
  Xcode's iOS simulator SDK build to (the SDK's `SystemVersion.plist`), preferred first, for the Mac's architecture.
  When the list can't be read, the tab offers the download without a size.
- **No Android SDK:** Install reads Google's package lists (`dl.google.com/android/repository/repository2-3.xml` and
  the Google Play system images' `sys-img2-3.xml`) and offers what is missing on the stable channel: platform-tools,
  the emulator for the Mac, and, when there is no AVD at all, the newest Google Play system image for the Mac's ABI
  (unless one is already in the SDK) and an AVD on it named `Yardlet_Phone`. The tab shows the total size and the
  licenses' full text; Accept and Download starts it. No Java is needed: Yardlet downloads each archive, checks it
  against the SHA-1 the list gives, unpacks its one folder where sdkmanager would (each holds its
  `source.properties`, which Android Studio and sdkmanager read), records each license's acceptance as sdkmanager
  does (the SHA-1 of its text on a line of `licenses/<id>`), and writes the AVD's `<name>.ini` and `config.ini` as
  Android Studio does. The SDK folder is the existing one the environment, the login shell's `PATH` or Android
  Studio's place names, else Android Studio's place (`~/Library/Android/sdk`), made then. A failed install removes
  what it made.

When an install ends, the platform is checked again and its devices are listed.

## Removing what Yardlet installed

Yardlet writes down what it installed (`Simulator/installed.json` in its Application Support folder, gone when
empty): each iOS runtime by the identifier `simctl runtime list` gives it, each Android package by its folder and
the revision it unpacked, the AVD, and the SDK folder when Yardlet made it.

Turning Settings › General › Simulator off asks whether to remove them, listing each with its size; Keep leaves them.
Only what is still as Yardlet left it is listed: a runtime `simctl` still lists as deletable, a package whose
`source.properties` still names the revision Yardlet unpacked (one Android Studio updated is no longer Yardlet's),
an AVD still there. Removing runs `xcrun simctl runtime delete <identifier>` for a runtime and deletes the package
folders and the AVD's files; the SDK folder goes last, only when nothing but the licenses Yardlet accepted is left in
it. What could not be removed is said with why. What Xcode, Android Studio or the person installed is never listed.
Finding the switch off at launch asks nothing.

## Picking a device

With no device attached, the tab lists the devices: those that are on first, under Running, then the iOS
simulators by runtime, newest first, then the Android emulators by API level; an Android device, always on while
it is listed, is under Running. A device another task claims says
"Used by" and that task's title.

Picking a device attaches it to the task and claims it when no task does. A device that is off starts without a
window (`simctl boot`), with "Starting iPhone 17…" in the tab while it boots; such a device is one Yardlet
started (below). An attached device that shut down elsewhere shows "This simulator is off." with Turn On.

An Android emulator that is off starts without a window, without sound, and with its GPU on the Mac's
(`emulator -avd <name> -no-window -gpu host -no-boot-anim -no-audio -port <port>`, on the first free console
port from 5554), ready once the device says it has booted (`sys.boot_completed`). Without sound, the emulator
does not use the Mac's microphone, so it asks for no microphone access in Yardlet's name; the AVD's own
settings are not changed. It never starts read-only: what is installed or changed in the device stays, as in
Android Studio. An emulator already running, from Android Studio for one, is used where it runs and not started
again. An Android device is shown as it is and never started or stopped, so its device menu has no Shut Down; one
that goes away, unplugged or out of reach, leaves the list, and its tab lists the devices until it is back.

Apart from the AVD an Android install makes (above), Yardlet does not create, delete or erase simulators or
emulators; that is Xcode's and Android Studio's part.

## Several tasks and one device

A simulator is shared by the whole Mac, so two words keep apart what a task has:

- **Attached:** the device a task chose. At most one per task, kept in the task's workspace snapshot, so it
  survives a relaunch. The task's Simulator tab shows it.
- **Claimed:** the right of the task's agent to send the device input. One task per device, kept in memory
  only; after a relaunch a task claims its device again when it next needs it, unless another task has.

The rules:

1. Watching is free. Several tasks' tabs can show the same device at once; the simulator host makes each frame
   once and every tab that shows the device gets it.
2. One task claims a device. Picking a device another task claims attaches it for watching, and its device menu
   offers "Use in This Task", which moves the claim.
3. The person's hands come first. Touches and keys from any tab showing a device go in at once, claimed or not.
   Each one notes the time on the device (`SimulatorCenter.lastPersonInput(on:)`), in memory.

Disconnect in the device menu, picking another device, and archiving or deleting the task release both the
attachment and the claim. Closing the tab or hiding the panel releases neither.

Yardlet cannot see what moves a device from outside it (Simulator.app, Xcode, other tools); the tab always shows
what the device draws, so the screen is right, but input from both may mix.

## Devices Yardlet starts

Yardlet writes down each device it starts, with that boot: for an iOS simulator, the device's `launchd_sim`
process ID, read from CoreSimulator's launchd job for the device, and the process's start time; for an Android
emulator, the emulator's process ID, its start time and its AVD's name. The record is
`Simulator/started-devices.json` in Yardlet's Application Support folder, which nothing creates until a device
starts and which goes when it empties. Before stopping a device, Yardlet checks that the same process still runs
it, so a device started again elsewhere, after a crash or a restart, is never stopped.

Yardlet stops a device it started (`simctl shutdown`; `adb emu kill` for an emulator, which keeps its quick-boot
snapshot, as Android Studio's stop does):

1. ten minutes after no task attaches it and no tab shows it;
2. thirty minutes after the last turn, tool call or shown tab of the tasks that attach it, never while one of
   their turns runs;
3. when Yardlet quits, and when the switch turns off.

A Yardlet that ended without stopping them stops, at its next start with the switch on, those still on in the
same boot that no task attaches. Devices started elsewhere are never stopped. The device menu of a device Yardlet
started offers Shut Down and says that Yardlet started it and shuts it down when no task uses it, since work done
outside Yardlet (debugging in Xcode, for one) does not keep it on. The times are not settings.

## The screen

The screen is fit into the tab, keeping its proportions, with the room around it left empty and no bezel.

The simulator host (`Contents/Helpers/Yardlet Simulator Host.app`) shows the screens: one process per Xcode,
started responsible for itself, so it asks for no permission in Yardlet's name and Yardlet needs no screen
recording or accessibility permission. It attaches a booted device when the first tab starts showing it, and lets
go ten seconds after the last one stops, so going to another tab and back does not attach it again; it ends a
minute after it lets go of its last device, and when Yardlet ends.

Each frame is an IOSurface the host copies once, at the largest size any tab shows the device at, and sends over a
Mach port. The tab's layer takes it on the host's pipe queue, in a transaction of its own, so a moving screen
costs the main thread nothing a frame. While nobody can see a tab (its window covered, minimized, on another
space, the app hidden, or the tab not shown) it asks for no frames, and a still screen sends none.

An Android emulator's or device's screen comes from the scrcpy server (scrcpy 5.0.1), which the app bundle carries
unchanged as `Contents/Resources/scrcpy-server` and checks against its SHA-256 before each use. When a tab starts
showing one, Yardlet copies the server to the device's `/data/local/tmp`, starts it with `adb shell`, and connects
to it through an adb forward tunnel, so Yardlet opens no listening port; the server removes its file as it starts.
The server sends the screen as H.264, at most 1,280 pixels on its longer side and 4 to 8 Mbps, as sharp as the
largest tab needs. VideoToolbox decodes it off the main thread into IOSurfaces that the tab's layer takes as it
takes the host's, so here too a moving screen costs the main thread nothing a frame. The stream runs only while a
tab shows the device: when the last one stops showing it, the stream, the server and the tunnel end. When the
device turns, the server starts a new capture and the tab turns with it.

When the host cannot show the device, the tab says "The simulator's screen can't be shown." and why, in its own
words: the helper is missing from the app (reinstall Yardlet), it couldn't start, it stopped, it couldn't connect to
the simulator, or the connection ended. For an Android emulator the reasons are that the scrcpy server is missing
from the app (reinstall Yardlet), Yardlet couldn't connect to the emulator, or the connection ended; an Android
device's tab says "The device's screen can't be shown." with the same reasons for the device. Try Again
starts the helper or the stream again; a missing helper or server offers none. The error behind it goes to the log
(`NSLog`), not to the tab. A build run outside an app bundle (`swift run`) starts the `YardletSimulatorHost` built
beside it.

## Input

- A press, a drag and a release are one finger, sent to an iOS simulator's digitizer, or to an Android
  emulator's or device's touchscreen through the scrcpy server.
- A trackpad scroll is a finger put down under the pointer (kept off the screen's edges, so it starts no edge
  gesture), dragged by the scroll's distance and lifted when the fingers leave the trackpad; the glide after it is
  the device's own. A mouse wheel's clicks drag the same way, lifted when the wheel rests. HID scroll messages are
  not used: sent to a service an iPhone does not have, they crash the device's `backboardd`.
- With the screen focused, keys go to the device by their place on the keyboard, past the Mac's input method,
  so the device's own keyboard layout composes text: to an iOS simulator as HID keys, to an Android emulator or
  device as Android key codes, each carrying the modifiers held. Shift, Control, Option and Command go down and up as keys; Caps Lock, which
  switches the device's keyboard between its languages, is pressed once at each change. Held keys are not
  repeated by the Mac; the device repeats them itself. Every key held and the finger are let go when the screen
  loses the keyboard or shows another device.
- ⇧⌘H is Home, on either platform, and ⌘L an iOS simulator's lock button, as in Simulator.app. ⌘W closes the tab. The window's keys (⌘1–⌘4, ⌥⌘B,
  ⌘J) and the menus' keys are Yardlet's first; every other key goes to the device.

## The tab's header

- iOS devices have a Home button; Android devices have Back, Home and Recents, in the order of Android's
  navigation bar.
- The device menu: Switch Device (the list of devices), "Use in This Task" when another task claims the device,
  Disconnect, "Revoke Agent Access" when the person let agents use the device (below, "Agent tools"), and for a
  device Yardlet started and still on, Shut Down with a note that Yardlet shuts it down when no task uses it.

Rotation, appearance, location, pinching and the Mac's clipboard are not in the tab.

## Agent tools

A task's agent sees and drives the device its task attached through ten tools of Yardlet's MCP server
(docs/AGENT_BROWSER_TOOLS.md, "Simulator tools"). A task gets them when the switch was on as its session started or
resumed, as "Agent browser tools" works, while a platform's devices can be used: a running task's list gains them
once the check finds a usable Xcode or Android SDK, and loses them when the switch turns off, as nothing runs then.
Android emulators and devices are driven the same way, through the scrcpy stream their Simulator tab uses ("The
screen"). A real device is asked for in each task, with what it can reach (below).

| Tool | Arguments | Behavior |
|---|---|---|
| `simulator_list` | none | JSON `{devices:[{device, platform, name, os, state, realDevice, attached, usedBy, startedByYardlet, shown}], note}`: every listed device with its id (an iOS simulator's UDID; an Android emulator's adb serial while it runs, else its AVD name; an Android device's adb serial), whether it is a real device, whether this task attached it, the task whose agent uses it ("this task" or that task's title), whether Yardlet started it and whether a Simulator tab shows it. The note names a platform that cannot be used and why. Read-only |
| `simulator_attach` | `device` (required: an id or a name) | After the person's approval (below), attaches the device to the task and claims it, starting it when it is off and waiting until it is ready. Shows the task's Simulator tab; while the person uses another tab of the panel, the Simulator tab joins the strip beside it and the result says so. The result gives the id to pass to the agent's own build and install tools (`xcrun simctl install <id> <app>`; `adb -s <id> install <apk>` on Android), the screen's size in points (dp on Android), and whether Yardlet started the device (it then shuts down when unused), it was on before (another app may be using it), or it is a real device (the person's own accounts may be signed in on it, and Yardlet never turns it on or off). Refused: an unknown id or name, a name several devices share (naming them), a device another task's agent uses (with that task's title), a start past the two devices Yardlet runs for agents; each names the devices that are on and free |
| `simulator_detach` | none | Lets go of the attachment and the claim. A device Yardlet started shuts down ten minutes after no task attaches it |
| `simulator_screenshot` | `format` (png or jpeg) | The screen at its size in points (402×874 for an iPhone 17) or dp (411×914 for a Pixel 6), which the result names. An Android device's is the stream's last frame, scaled to dp |
| `simulator_snapshot` | none | The app in front's accessibility elements as indented text, `- button "General" [id=com.apple.settings.general] [ref=@e6]`: each element's role, label, value and id (an iOS accessibility identifier, an Android resource id). Groups and layouts without a label or value are read through. Elements whose middle is on the screen get a reference for `simulator_tap`; the others say `[off screen]`. The references belong to the task's latest snapshot of that device. Labels, values and ids are scrubbed as the browser tools' results are (docs/AGENT_BROWSER_TOOLS.md, "Keys and tokens") and cut at 200 characters, and the text at 40,000. On iOS the simulator host reads the device's accessibility runtime through macOS's AccessibilityPlatformTranslation (`AXPTranslator`, the way Xcode's Accessibility Inspector and idb read it), at most 600 elements or 15 seconds; on Android, UI Automator (`adb exec-out uiautomator dump /dev/tty`), with bounds turned into dp. UI Automator gives up while an animation keeps running, which the result says |
| `simulator_tap` | `x` and `y`, or `ref`; `duration` | One finger down and up at the point, or at the middle of the element `ref` names in the latest snapshot; held longer than 0.5 seconds, a long press. A reference not in that snapshot is `not_found`, naming `simulator_snapshot` |
| `simulator_swipe` | `x`, `y`, `x2`, `y2` (required), `duration` (0.3 by default) | One finger moved in even 16 ms steps from the first point to the second. One that starts within 4 points of an edge is the system's edge gesture, which the description says |
| `simulator_type` | `text` (required), `method` (`paste`, the default, or `keys`) | `paste` reads the text on the device's clipboard (`simctl pbpaste`), puts the text there (`simctl pbcopy`, given a UTF-8 locale, without which it refuses text outside ASCII), presses ⌘V as hardware keys and puts the earlier text back half a second later. Text in any language goes in as written, and iOS asks no "Allow Paste", since the paste comes from the keyboard. `keys` types ASCII as hardware keys, which the device reads with its own keyboard layout, so the text goes in as written only while that layout is English; the result says so. The agent uses `keys` for a field that refuses a paste (the text does not appear) or when the clipboard cannot be used, as the description and the results say. Yardlet does not judge a paste from the screen, which changes anyway (a blinking cursor, search suggestions). Something other than text on the device's clipboard does not come back. On Android, `paste` uses scrcpy's clipboard messages: it asks for the clipboard (`GET_CLIPBOARD`), sets the text with the paste flag (`SET_CLIPBOARD`, which the device acknowledges once it has pressed its paste key), and half a second later sets the earlier text back without pasting; a clipboard with no text, which the device does not answer, is left with empty text. `keys` is scrcpy's text injection (`INJECT_TEXT`): key events the device makes from the text with its own key map |
| `simulator_press` | `button` or `key`, `count` (1 to 50) | An iPhone's buttons: home, lock, volume_up, volume_down and action (back, recents and power are Android's, refused on an iPhone). An Android emulator's or device's: back, home, recents, power, volume_up and volume_down, as scrcpy key events with Android's key codes (lock and action are refused). Keys: return, delete, tab, escape, space, up, down, left, right and select_all (⌘A on iOS, Control-A on Android) |
| `simulator_handoff` | `reason` (required), `timeout` (seconds, 600 by default) | Hands the attached device to the person for a step only they can take (signing in with their own account, approving a payment, a CAPTCHA) and waits, as `browser_handoff` hands a tab (docs/AGENT_BROWSER_TOOLS.md, "2. Tools"): after the person's approval, and starting the device again if it shut down, it shows the task's Simulator tab with a bar above the device ("The agent handed this device to you", the reason, "Decline" and "I'm done") and posts a macOS notification ("The agent needs you on iPhone 17", the task's title and the reason), whose click opens the task with the tab. Returns on the person's answer, on a message the person sends the task instead (the result says so and that the message comes with it, as `browser_handoff`'s does), at the end of the turn, when the device is let go (`simulator_detach`, another device picked in the tab, the switch turned off), or at the timeout (within the harness limit `SessionToolPolicy.waitCeiling`, and a day at most). After the timeout the device stays handed over with its bar, and the next call waits on it again with its new reason and gets an answer given meanwhile; the turn's end takes the bar and the notification away. It sends the device nothing, and the agent's other tools still act on it meanwhile. No `text` to wait for: `simulator_snapshot` reads the screen once the call returns; the panel has no Face ID or fingerprint control, so the description does not offer those steps. A phone following the Mac (docs/REMOTE_PROTOCOL.md) does not show the handoff |

**The person's approval.** The first time a task's agent uses a device, Yardlet asks on the request card in the
task ("Let this task use the iPhone 17 simulator?"), whatever the task's permission mode, as the Claude app asks once
for each device. The call waits for the answer as the browser tools' `file:` approval does: unanswered, the card is
declined when the turn stops, or after ten minutes. Declined, the call is `refused` and nothing reaches the device.

- A simulator's approval holds for every task, so a scheduled run uses a device the person allowed before, and one
  not allowed yet waits on its card and is declined. It is kept in Yardlet's preferences
  (`YardletSimulatorApprovedDevices`): turning the switch off removes every approval, and removing Yardlet removes its
  preferences with them.
- A real device's approval holds only in the task it was given in, and only while Yardlet runs; its card adds that
  with real accounts signed in, the agent can send messages or make payments, and that pictures and text from
  its screen are sent to the model's provider.
- "Revoke Agent Access" in the device menu takes an approval back in every task; the next tool on the device asks
  again.

**What the code holds the agent to.**

- Every tool but `simulator_list` and `simulator_attach` acts on the task's attached device, and no tool attaches one
  by itself: a device that is on may be the person's own in Simulator.app or another task's QA device. Without an
  attached device a tool answers `not_found`, naming the devices and `simulator_attach`.
- Positions are points (dp on Android) of the last screenshot, checked to be on the screen. A reference stands for
  the middle of its element in the task's latest snapshot of the device; attaching or detaching drops the snapshot.
  A duration is at most 10 seconds, a count at most 50, a text at most 1,000 characters; past these the call is
  `invalid_arguments` with the range, before anything reaches the device.
- Before each tool the device is claimed again and, when the idle rules shut it down, started again under the attach's
  rules, which the result says. Each tool counts as a use for the idle rules.
- The person's touch, scroll or key on the device in the last 30 seconds is said in the result ("The person is using
  iPhone 17 in a Simulator tab"); it does not stop the agent's input.
- The tools attach a device through the panels' simulator host or, for an emulator, its scrcpy stream, so a device a
  tab shows and the tools drive is attached once. The tools hold it attached for two minutes after their last call,
  or until `simulator_detach`; meanwhile an emulator's stream runs whether or not a tab shows it, at up to 1,280
  pixels on its longer side.

**What the agent's own tools do.** Building, installing, launching, logs and debugging are not simulator tools: the
agent passes the device's id to its own (`xcrun simctl` or `adb` in its shell, a build tool's simulator id, Xcode's
run destination), under its harness's own permissions. Another tool with a session open on the same device (XcodeBuildMCP,
Xcode's device interaction) may drive it meanwhile; the tools' descriptions say the agent may leave the input to it,
and that input from outside Yardlet mixes with theirs.

Do not sign in to real accounts on a device an agent uses, and do not hand an agent an app whose terms forbid
automation.

## Checking it

- `TaskSurfaceNavigationProjectionTests` and `SimulatorCenterTests` check the tab's place in the panel, the
  launcher's order and the device menu's items. `SimulatorCenterTests` also checks the agent tools: the list each task
  gets, the attached device only, approvals and their reach, positions turned into fractions of the screen, the
  limits, a snapshot's text and references (scrubbed, groups read through, off-screen elements without one), a tap by
  reference at its element's middle, a handoff answered from the tab's bar, by a message or by the turn's end, and
  timing out to wait again, and that a real device is asked for in each task.
- `SessionToolRenderingTests` draws the approval cards of a simulator and of a real device under
  `.build/session-tools-qa/`.
- `SimulatorPanelRenderingTests` draws each state of the tab with fictional devices (the list, each missing
  part, a saved tab whose Xcode is gone, booting, off, a device handed to the person and once answered, an
  unsupported Xcode, a screen that could not be shown) in both appearances under `.build/simulator-panel/`.
- `SimulatorInstallTests` checks Install without downloading or installing anything: the iOS runtime's size from a
  fixture of Apple's list and a fake `xcodebuild` in a fake Xcode, and the Android SDK from fixture archives laid out
  as Google's, checked against their SHA-1 and unpacked into a temporary home, then removed. The rendering test also
  draws each Install state and the question the switch asks.
- `scripts/simulator-qa/run-check.sh` runs `SimulatorHostQATests` and `SimulatorPanelQATests` against a
  simulator it makes, boots without a window and deletes afterwards: the live screen, a click, a trackpad scroll,
  Home and typing, through the helper, and the agent tools' select-all and paste, which puts the device's clipboard
  back. Simulators it did not make are left alone.
- `AndroidSimulatorTests` check the SDK's lookup and the device list against recorded output (Android devices
  known by the serial number they report, asked once a connection, never started), the scrcpy
  protocol, the decoding of a stream across a rotation, the keys' codes and modifiers, UI Automator's dump in dp, and
  that the bundle carries the server file the client checks.
- `scripts/simulator-qa/run-android-check.sh` runs `AndroidScreenQATests` against an AVD it makes in a folder of its
  own, starts without a window and deletes afterwards: how long decoding takes, the first frame, Back, Home and
  Recents, a swipe, typing, a turn, screenshots, and that the stream and the server end with the last tab.
  `scripts/simulator-qa/run-android-panel-check.sh` does the same in the running app's tab, as below, and runs
  `drive-tools.py` on the emulator: Back, Recents, Home, the volume keys and Power, Settings' search opened with
  `adb`, its field found by its resource id in a snapshot and tapped by reference, a paste in Korean that the next
  snapshot reads and after which the emulator's clipboard holds what it held before, select-all and keys, and the
  handoffs below. It then connects the same emulator again at its adb port (`adb connect 127.0.0.1:<port>`), which
  adb treats as a
  device reached over the network: the tab lists it by the serial number it reports, shows and drives it, offers no
  Shut Down, and the agent tools ask for it on the real device's card in the task, then take its screenshot, press
  Recents and read it with a snapshot. The QA app sends adb commands only to emulators and that address, so
  a phone plugged into the Mac is neither asked anything nor listed.
- `scripts/simulator-qa/run-panel-check.sh` does the same in the running app: a QA bundle launched in the
  background with a temporary home follows the switch, lists and attaches its simulator, shows it live through
  the bundle's simulator host, takes a click, and closes the tab when the switch turns off. Before that,
  `drive-tools.py` calls the agent tools through the bundle's `yardlet-mcp` as a harness does: the fixture captures
  the approval card in the task and allows it, and the calls attach the device beside the tab the person uses, tap,
  swipe, paste, type keys and press buttons, and are refused out of bounds; a snapshot of Settings gives General's
  row a reference whose tap opens General. Their handoffs show the Simulator tab with its bar, which the fixture
  captures: one left to time out, then, called again, answered with I'm done, and one declined. Turning the switch off
  removes the approval.

The performance bench's `simulator-scroll` scene scrolls a long conversation beside a Simulator tab whose
screen is still and then changes 60 times a second (docs/PERFORMANCE_BENCH.md, "2. Scenes").
