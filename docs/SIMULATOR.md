# Simulators in the side panel

A task's side panel can hold a Simulator tab: an iOS simulator's screen, live, which the person uses with the
mouse, the trackpad and the keyboard as on the device. Yardlet runs the simulators of the person's own Xcode
without opening Simulator.app, and changes nothing in Xcode's settings or its list of simulators.

The code:

- `Sources/NativeHarnessClient/Simulator/`: the devices, which task attaches and claims each, and the devices
  Yardlet started (`SimulatorCenter`); the Settings switch (`SimulatorPreference`); the device menu's items
  (`SimulatorDeviceMenu`).
- `Sources/NativeHarnessClient/Platform/macOS/Simulator/`: the iOS simulators through `simctl`
  (`MacIOSSimulatorBackend`), the simulator host's process and protocol client, the panels' screens
  (`MacSimulatorScreens`), the tab (`SimulatorPane`) and the screen view with the person's input
  (`SimulatorScreenView`).
- `Sources/YardletSimulatorHost/`: the simulator host, a helper executable in the bundle that opens Xcode's
  SimulatorKit at run time.
- The agents' tools: their definitions (`Sources/YardletAgentTools/SimulatorToolCatalog.swift`), their checks and
  results (`Sources/NativeHarnessClient/AgentTools/SimulatorAgentTools.swift`), the person's approvals
  (`SimulatorApprovals`), and the iOS simulators' screenshots and input (`MacIOSSimulatorDriver`).

## Turning it on and off

Settings › General › Simulator turns the feature on and off. It is on by default, and Yardlet's Mac app is the
only one that offers it. An agent that changes it through Yardlet's settings tools asks the person every time.

- On: once the saved tasks are read at launch, Yardlet checks this Mac's Xcode off the main thread and lists
  the simulators. Simulator is offered in the side panel's launcher and + menu.
- Off: Simulator leaves the launcher and the + menu, open Simulator tabs close, the simulator host ends, and
  the devices Yardlet started shut down. Nothing runs while it is off: no command and no file.

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
| Xcode's first launch or CoreSimulator | Xcode isn't set up yet. Open Xcode once and finish its setup, then come back. |
| An iOS runtime | No iOS simulator runtime. Add an iOS runtime in Xcode › Settings › Components. |
| Support for this Xcode in the simulator host | This Xcode isn't supported yet. Yardlet can't show simulator screens with Xcode 27.2 yet. |

Simulator stays in the launcher and the + menu either way; the switch is the way to hide it. A saved Simulator
tab whose device is attached while Xcode is gone says only "Xcode can't be found.", with Close. Yardlet does not
install Xcode or runtimes.

The check runs when the switch turns on and each time a Simulator tab appears; the tab also reads the devices
again then. Nothing reads them on a timer.

## Picking a device

With no device attached, the tab lists the iOS simulators: those that are on first, under Running, then the rest
by runtime, newest first. A device another task claims says "Used by" and that task's title.

Picking a device attaches it to the task and claims it when no task does. A device that is off starts without a
window (`simctl boot`), with "Starting iPhone 17…" in the tab while it boots; such a device is one Yardlet
started (below). An attached device that shut down elsewhere shows "This simulator is off." with Turn On.

Yardlet does not create, delete or erase simulators; that is Xcode's part.

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

Yardlet writes down each device it starts, with that boot: the device's `launchd_sim` process ID, read from
CoreSimulator's launchd job for the device, and the process's start time. The record is
`Simulator/started-devices.json` in Yardlet's Application Support folder, which nothing creates until a device
starts and which goes when it empties. Before stopping a device, Yardlet checks that the same process still runs
it, so a device started again elsewhere, after a crash or a restart, is never stopped.

Yardlet stops a device it started (`simctl shutdown`):

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

When the host cannot show the device, the tab says "The simulator's screen can't be shown." and why, in its own
words: the helper is missing from the app (reinstall Yardlet), it couldn't start, it stopped, it couldn't connect to
the simulator, or the connection ended. Try Again starts the helper again when it is not running; a missing helper
offers none. The error behind it goes to the log (`NSLog`), not to the tab. A build run outside an app bundle
(`swift run`) starts the `YardletSimulatorHost` built beside it.

## Input

- A press, a drag and a release are one finger, sent to the device's digitizer.
- A trackpad scroll is a finger put down under the pointer (kept off the screen's edges, so it starts no edge
  gesture), dragged by the scroll's distance and lifted when the fingers leave the trackpad; the glide after it is
  the device's own. A mouse wheel's clicks drag the same way, lifted when the wheel rests. HID scroll messages are
  not used: sent to a service an iPhone does not have, they crash the device's `backboardd`.
- With the screen focused, keys go to the device as HID keys, past the Mac's input method, so the device's own
  keyboard layout composes text. Shift, Control, Option and Command go down and up as keys; Caps Lock, which
  switches the device's keyboard between its languages, is pressed once at each change. Held keys are not
  repeated by the Mac; the device repeats them itself. Every key held and the finger are let go when the screen
  loses the keyboard or shows another device.
- ⇧⌘H is Home and ⌘L the lock button, as in Simulator.app. ⌘W closes the tab. The window's keys (⌘1–⌘4, ⌥⌘B,
  ⌘J) and the menus' keys are Yardlet's first; every other key goes to the device.

## The tab's header

- iOS devices have a Home button.
- The device menu: Switch Device (the list of devices), "Use in This Task" when another task claims the device,
  Disconnect, "Revoke Agent Access" when the person let agents use the device (below, "Agent tools"), and for a
  device Yardlet started and still on, Shut Down with a note that Yardlet shuts it down when no task uses it.

Rotation, appearance, location, pinching and the Mac's clipboard are not in the tab.

## Agent tools

A task's agent sees and drives the device its task attached through eight tools of Yardlet's MCP server
(docs/AGENT_BROWSER_TOOLS.md, "Simulator tools"). A task gets them when the switch was on as its session started or
resumed, as "Agent browser tools" works, while a platform's devices can be used: a running task's list gains them
once the check finds a usable Xcode, and loses them when the switch turns off, as nothing runs then.

| Tool | Arguments | Behavior |
|---|---|---|
| `simulator_list` | none | JSON `{devices:[{device, platform, name, os, state, attached, usedBy, startedByYardlet, shown}], note}`: every listed device with its id (an iOS simulator's UDID), whether this task attached it, the task whose agent uses it ("this task" or that task's title), whether Yardlet started it and whether a Simulator tab shows it. The note names a platform that cannot be used and why. Read-only |
| `simulator_attach` | `device` (required: an id or a name) | After the person's approval (below), attaches the device to the task and claims it, starting it when it is off and waiting until it is ready. Shows the task's Simulator tab; while the person uses another tab of the panel, the Simulator tab joins the strip beside it and the result says so. The result gives the id to pass to the agent's own build and install tools (`xcrun simctl install <id> <app>`), the screen's size in points, and whether Yardlet started the device (it then shuts down when unused) or it was on before (another app may be using it). Refused: an unknown id or name, a name several devices share (naming them), a device another task's agent uses (with that task's title), a start past the two devices Yardlet runs for agents; each names the devices that are on and free |
| `simulator_detach` | none | Lets go of the attachment and the claim. A device Yardlet started shuts down ten minutes after no task attaches it |
| `simulator_screenshot` | `format` (png or jpeg) | The screen at its size in points (402×874 for an iPhone 17), which the result names |
| `simulator_tap` | `x`, `y` (required), `duration` | One finger down and up at the point; held longer than 0.5 seconds, a long press |
| `simulator_swipe` | `x`, `y`, `x2`, `y2` (required), `duration` (0.3 by default) | One finger moved in even 16 ms steps from the first point to the second. One that starts within 4 points of an edge is the system's edge gesture, which the description says |
| `simulator_type` | `text` (required), `method` (`paste`, the default, or `keys`) | `paste` reads the text on the device's clipboard (`simctl pbpaste`), puts the text there (`simctl pbcopy`, given a UTF-8 locale, without which it refuses text outside ASCII), presses ⌘V as hardware keys and puts the earlier text back half a second later. Text in any language goes in as written, and iOS asks no "Allow Paste", since the paste comes from the keyboard. `keys` types ASCII as hardware keys, which the device reads with its own keyboard layout, so the text goes in as written only while that layout is English; the result says so. The agent uses `keys` for a field that refuses a paste (the text does not appear) or when the clipboard cannot be used, as the description and the results say. Yardlet does not judge a paste from the screen, which changes anyway (a blinking cursor, search suggestions). Something other than text on the device's clipboard does not come back |
| `simulator_press` | `button` or `key`, `count` (1 to 50) | An iPhone's buttons: home, lock, volume_up, volume_down and action (back, recents and power are Android's, refused on an iPhone). Keys: return, delete, tab, escape, space, up, down, left, right and select_all (⌘A) |

**The person's approval.** The first time a task's agent uses a device, Yardlet asks on the request card in the
task ("Let this task use the iPhone 17 simulator?"), whatever the task's permission mode, as the Claude app asks once
for each device. The call waits for the answer as the browser tools' `file:` approval does: unanswered, the card is
declined when the turn stops, or after ten minutes. Declined, the call is `refused` and nothing reaches the device.

- A simulator's approval holds for every task, so a scheduled run uses a device the person allowed before, and one
  not allowed yet waits on its card and is declined. It is kept in Yardlet's preferences
  (`YardletSimulatorApprovedDevices`): turning the switch off removes every approval, and removing Yardlet removes its
  preferences with them.
- A real device's approval holds only in the task it was given in, and only while Yardlet runs; its card adds that
  with real accounts signed in, the agent can send messages or make payments, and that pictures of its screen are sent
  to the model's provider.
- "Revoke Agent Access" in the device menu takes an approval back in every task; the next tool on the device asks
  again.

**What the code holds the agent to.**

- Every tool but `simulator_list` and `simulator_attach` acts on the task's attached device, and no tool attaches one
  by itself: a device that is on may be the person's own in Simulator.app or another task's QA device. Without an
  attached device a tool answers `not_found`, naming the devices and `simulator_attach`.
- Positions are points of the last screenshot, checked to be on the screen. A duration is at most 10 seconds, a count
  at most 50, a text at most 1,000 characters; past these the call is `invalid_arguments` with the range, before
  anything reaches the device.
- Before each tool the device is claimed again and, when the idle rules shut it down, started again under the attach's
  rules, which the result says. Each tool counts as a use for the idle rules.
- The person's touch, scroll or key on the device in the last 30 seconds is said in the result ("The person is using
  iPhone 17 in a Simulator tab"); it does not stop the agent's input.
- The tools attach a device through the panels' simulator host, so a device a tab shows and the tools drive is
  attached once. The tools hold it attached for two minutes after their last call, or until `simulator_detach`.

**What the agent's own tools do.** Building, installing, launching, logs and debugging are not simulator tools: the
agent passes the device's id to its own (`xcrun simctl` in its shell, a build tool's simulator id, Xcode's run
destination), under its harness's own permissions. Another tool with a session open on the same device (XcodeBuildMCP,
Xcode's device interaction) may drive it meanwhile; the tools' descriptions say the agent may leave the input to it,
and that input from outside Yardlet mixes with theirs.

Do not sign in to real accounts on a device an agent uses, and do not hand an agent an app whose terms forbid
automation.

## Checking it

- `TaskSurfaceNavigationProjectionTests` and `SimulatorCenterTests` check the tab's place in the panel, the
  launcher's order and the device menu's items. `SimulatorCenterTests` also checks the agent tools: the list each task
  gets, the attached device only, approvals and their reach, positions turned into fractions of the screen, and the
  limits.
- `SessionToolRenderingTests` draws the approval cards of a simulator and of a real device under
  `.build/session-tools-qa/`.
- `SimulatorPanelRenderingTests` draws each state of the tab with fictional devices (the list, each missing
  part, a saved tab whose Xcode is gone, booting, off, an unsupported Xcode, a screen that could not be shown)
  in both appearances under `.build/simulator-panel/`.
- `scripts/simulator-qa/run-check.sh` runs `SimulatorHostQATests` and `SimulatorPanelQATests` against a
  simulator it makes, boots without a window and deletes afterwards: the live screen, a click, a trackpad scroll,
  Home and typing, through the helper, and the agent tools' select-all and paste, which puts the device's clipboard
  back. Simulators it did not make are left alone.
- `scripts/simulator-qa/run-panel-check.sh` does the same in the running app: a QA bundle launched in the
  background with a temporary home follows the switch, lists and attaches its simulator, shows it live through
  the bundle's simulator host, takes a click, and closes the tab when the switch turns off. Before that,
  `drive-tools.py` calls the agent tools through the bundle's `yardlet-mcp` as a harness does: the fixture captures
  the approval card in the task and allows it, and the calls attach the device beside the tab the person uses, tap,
  swipe, paste, type keys and press buttons, and are refused out of bounds. Turning the switch off removes the
  approval.

The performance bench's `simulator-scroll` scene scrolls a long conversation beside a Simulator tab whose
screen is still and then changes 60 times a second (docs/PERFORMANCE_BENCH.md, "2. Scenes").
