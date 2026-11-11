# Keeping the Mac awake while tasks work

Yardlet keeps the Mac from idle-sleeping while tasks work. Two settings in Settings › General, both off by
default, go further. The code is in `Sources/NativeHarnessClient/Platform/macOS/RunningWorkActivity.swift`,
`Sources/YardletLidSleep/` and `Sources/YardletLidHelper/`.

## Idle sleep

`AppModel.keepsMacAwake` is true while a provider turn or a bash-mode command runs in any task, and while a
task waits for an approval when remote connections are on and a device is paired, so that device can still
reach the Mac to answer it. Meanwhile Yardlet holds a process power assertion (`idleSystemSleepDisabled`), as
the Codex app does; the display may still sleep. No harness hook is involved.

Settings › Remote › "Keep this Mac awake on power" (off by default) holds the same assertion while remote
connections are allowed and the Mac is on power, tasks or not.

## Keep the screen unlocked while tasks work

While `keepsMacAwake` holds and this setting is on, Yardlet also prevents display sleep
(`idleDisplaySleepDisabled`), so the screen does not lock and a harness's computer use keeps working. It lets
go when the work ends.

- On battery below 20% it lets go, posts one notification and shows the state in the menu bar menu, until
  the battery allows again (read every minute).
- Heat does not count: the work goes on either way, and the display adds little heat.
- While it holds, the menu bar menu starts with "Keeping the screen unlocked" and Turn Off.

## Keep tasks working with the lid closed

Keeping a closed Mac awake needs root, so this setting uses a launch daemon inside the bundle.

- **Registration.** Turning the setting on registers it with `SMAppService.daemon`: property list
  `Contents/Library/LaunchDaemons/<app identifier>.lid-helper.plist` (from
  `Packaging/LidHelper-LaunchDaemon.plist`), program `Contents/Helpers/yardlet-lid-helper`. macOS asks the
  person to allow it once in System Settings › General › Login Items & Extensions, which a line under the
  setting says until then. Turning the setting off unregisters it.
- **The helper** turns on the system power setting `SleepDisabled` (what `pmset -a disablesleep 1` sets) only
  while a connected Yardlet says over XPC that its tasks are working and the battery and heat allow it. While
  it is on the Mac does not sleep at all, Apple menu › Sleep included. The setting outlives the process and a
  restart, so the helper turns it off when the work ends, when the connection ends (Yardlet quits, crashes or
  is killed), when the helper starts (once at every boot) and on SIGTERM (unregistered, shutdown).
- **The record file.** Before turning the setting on, the helper writes
  `/Library/Application Support/Yardlet/Lid Helper Turned Off Sleep.txt`, which says how to undo it by hand
  (`sudo pmset -a disablesleep 0`), and removes it once the setting is off. It turns off only a setting it
  turned on: one already on without its record (`pmset`, Amphetamine) is used and left alone. If it cannot
  write the record, it leaves `SleepDisabled` off.
- **Signing.** The app and the helper accept each other's XPC connection only when signed by the same team.
  The helper runs as root from a bundle its user can change, so its property list carries a launch constraint
  (`SpawnConstraint` with `team-identifier` and `signing-identifier`): launchd starts only an executable signed
  by Yardlet's team with the helper's identifier. `scripts/sign-app.sh` fills in the team; a bundle signed ad
  hoc carries no property list.
- **Timers.** A client's "working" lasts 10 minutes (`LidSleepGuard.lease`) unless said again; Yardlet says
  it every minute, so a Yardlet that stopped answering lets a closed Mac sleep within 10 minutes. The helper
  rechecks battery and heat every minute, and at once when the thermal state changes. With nothing connected
  and nothing to put back, it exits after 10 seconds, so no root process stays resident.
- **Battery and heat.** On battery below 20%, a closed Mac may sleep until it is on power. At `thermalState`
  serious with the lid closed, Yardlet notifies once and keeps working. At critical the Mac may sleep, which is
  what cools a closed Mac, until it is out of critical. Each pause posts one notification and shows in the
  menu bar menu. The helper applies the battery and critical rules itself too.
- **Menu bar.** While it holds, the menu starts with "Keeping tasks working with the lid closed" and Turn
  Off; while paused, with why it is not.
- **No helper.** A development run, a build signed ad hoc and a QA copy under another identifier have none
  ("Not available in this copy of Yardlet"); a UI fixture does not offer the setting.

## What stays behind

The assertions end with the process. The lid setting leaves the background item registration while it is
on, and `SleepDisabled` and the record file while tasks work, which go back when Yardlet quits. Deleting the
app with the setting on leaves only the registration, with nothing left to run. `SleepDisabled` stays only
if the helper is killed while holding and the app is deleted before it starts again; the record file then
says how to undo it.

## What Yardlet does not do

- Change `pmset` display, idle-sleep or screen saver settings; outside the lid helper it uses only process
  assertions.
- Keep the display on or a closed Mac awake for an idle task.
- Share the whole Mac screen with a remote device; that is macOS Screen Sharing's job.
