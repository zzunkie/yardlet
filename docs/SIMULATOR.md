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

When the host cannot attach the device, the tab says "The simulator's screen can't be shown." with Try Again.

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
  Disconnect, and for a device Yardlet started and still on, Shut Down with a note that Yardlet shuts it down when
  no task uses it.

Rotation, appearance, location, pinching and the Mac's clipboard are not in the tab.

## Checking it

- `TaskSurfaceNavigationProjectionTests` and `SimulatorCenterTests` check the tab's place in the panel, the
  launcher's order and the device menu's items.
- `SimulatorPanelRenderingTests` draws each state of the tab with fictional devices (the list, each missing
  part, a saved tab whose Xcode is gone, booting, off, an unsupported Xcode, a screen that could not be shown)
  in both appearances under `.build/simulator-panel/`.
- `scripts/simulator-qa/run-check.sh` runs `SimulatorHostQATests` and `SimulatorPanelQATests` against a
  simulator it makes, boots without a window and deletes afterwards: the live screen, a click, a trackpad scroll,
  Home and typing, through the helper. Simulators it did not make are left alone.
- `scripts/simulator-qa/run-panel-check.sh` does the same in the running app: a QA bundle launched in the
  background with a temporary home follows the switch, lists and attaches its simulator, shows it live through
  the bundle's simulator host, takes a click, and closes the tab when the switch turns off.

The performance bench's `simulator-scroll` scene scrolls a long conversation beside a Simulator tab whose
screen is still and then changes 60 times a second (docs/PERFORMANCE_BENCH.md, "2. Scenes").
