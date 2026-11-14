# Calendar

The calendar shows the calendars of the Google Calendar, Outlook Calendar and Apple Calendar accounts connected in
Settings › Connectors beside tasks, as a word under Scheduled tasks: **Tasks · Agents · Mail · Calendar** (in
Korean, 작업 · 개인 에이전트 · 메일 · 캘린더). It shows a week or a day, answers Google and Outlook invitations, hands an
event to an agent by name, and lays Yardlet's scheduled runs over the days. Events stay on their service: the
calendar reads the days a screen shows while it shows them and keeps them in memory only.

## Turning it on and off

- Settings › General › **Calendar**, off by default. While it is off the Calendar word is not shown, and nothing is
  read or kept.
- Turning it off forgets every calendar and event read, stops reading, removes the two choices kept on disk (see
  "What is kept") and takes a window showing the calendar back to its tasks, at today and in the week. The calendar
  connectors and their Keychain items stay; they belong to Settings › Connectors.
- The English sidebar names Personal agents **Agents** in its row of words, so four words fit the narrowest sidebar;
  Settings, menus and titles keep "Personal agents".

## Accounts

- Every Google Calendar, Outlook Calendar and Apple Calendar connector that is connected is an account of the
  calendar (`ConnectorCenter.calendarAccounts`). Connecting, disconnecting or removing one adds it to or removes it
  from the calendar at once; what was read from a removed account is forgotten.
- Google and Outlook are read with the connector's own sign-in and session (`OAuthAPISession`), asking for nothing
  beyond the connector's permissions (docs/CONNECTORS.md, "Google" and "Microsoft 365"). The requests are the ones the
  connector's tools make, from the same code (`GoogleCalendarAPI`, `OutlookCalendarAPI`).
- Apple Calendar is what the Mac's Calendar app has synced, read through EventKit (`MacDataStoring`). The calendar only
  reads it; it never asks macOS for permission, which the connector asked for when it was turned on.
- An account the calendar cannot read shows why under its calendars; a refused sign-in says to sign in again in
  Settings › Connectors, and choosing the line opens that page.

## One calendar reached two ways

A Google or Outlook account added to the Mac's Calendar app too reaches Yardlet twice: through its connector and
through Apple Calendar. It is shown once, from its connector, which can answer invitations.

- A Mac calendar is taken for a connector's calendar when the account Calendar keeps it under is named with the
  connector account's address (in any case) and the calendar's name is that calendar's own name, or the name the
  person gave it on the service. Only an exact match counts, and only when the connector account has one calendar of
  that name (`CalendarCenter.copies`).
- While the connector reads the calendar, the Mac's copy is neither listed nor drawn. When the connector cannot read
  it, or its account needs to sign in again, the Mac's copy stands in: it is listed under Mac Calendar and its events
  are drawn. Showing or hiding a calendar applies to its Mac copy too.
- A Mac calendar that matches nothing, or matches more than one calendar, is shown as its own calendar.

## What is read, and when

- A window showing the calendar reads two ranges: the days shown, and the upcoming days the sidebar lists (today and
  the six days after it), as one range when they meet (`CalendarWindowState.readRanges`). The home's desk reads today
  while it shows (see "On the desk"). Nothing is read while neither shows, and nothing before one first shows.
- Each shown calendar's events in the range are read from its account, each account's at the same time. Calendars
  hidden in the sidebar are not read.
- What was read stands for five minutes (`CalendarCenter.refreshInterval`): showing the same days again within it reads
  nothing, and days that stay shown are read again every five minutes. A range read for a longer range that holds it
  is not read again on its own.
- Ranges no window shows any more are kept until five minutes pass, at most four of them, so going back a week does
  not read it again at once.
- Google: `calendarList`, then `events.list` for each calendar with `singleEvents` (a recurring event as its
  occurrences), up to four pages of 250. Outlook: `me/calendars`, then `calendarView` for each calendar in UTC. Apple:
  EventKit's events in the range. Cancelled Google and Outlook events are left out.

## What is kept

- In memory: each account's calendars, and the events of the ranges read. Nothing of an event is written to disk or to
  the log.
- On disk, in Yardlet's defaults: which calendars the person showed or hid, over each calendar's own default, by
  account and calendar ID (`Yardlet.calendarChoices`), and whether scheduled runs show (`Yardlet.calendarSchedules`).
  Turning the calendar off removes both.
- A calendar shows by default as its service shows it: Google's calendars that are selected in Google Calendar's
  list, every Outlook and Apple calendar.

## The sidebar

- **Upcoming:** what has not ended yet today and in the six days after, by day (Today, Tomorrow, then the date),
  at most eight rows: an event with its calendar's color, title and time (All day first), "Not replied" on an
  invitation that waits for an answer, and the scheduled runs with a clock while their layer shows. Choosing an event
  moves the days shown to its day, keeping Day or Week, and chooses it; choosing a run opens its scheduled task.
- **Calendars:** each account's calendars under its address and service, the Mac's under each account Calendar keeps
  them in (Mac Calendar · iCloud). A box in the calendar's color shows or hides it.
- **Yardlet › Scheduled runs:** shows or hides the runs of enabled scheduled tasks over the days.
- With no calendar account connected, the sidebar says where to connect one, with **Open Connectors**.

## The days

- The title bar's row holds the month and the days shown, **Today**, the previous and next arrows, and **Day** or
  **Week** (as the Mac's region starts a week).
- All-day events sit in a row above the hours: up to three a day, or two and "N more". Events sit at their times in the
  calendar's color, those that overlap side by side; an invitation not answered yet is drawn with a dashed outline.
  The hours open at 8 AM, or earlier when an event starts earlier, and today's column has a line at the current time.
- Scheduled runs are drawn as dashed lines with a clock at each time their trigger comes due, from when the schedule
  was made; choosing one opens its scheduled task.

## An event

Choosing an event shows it beside the days:

- Its title, day and times, and its calendar and account.
- For a Google or Outlook event the person was invited to: whether they answered, and **Accept** and **Decline**. The
  answer goes to the event's own service (Google with `sendUpdates=all`, Outlook with its `accept` or `decline` and a
  response sent), and shows at once. Apple Calendar cannot answer invitations through EventKit, so a Mac event shows no
  buttons.
- The number of people and who organized it, the meeting link named by its service (Google Meet, Microsoft Teams,
  Zoom, Webex, else "Join online") opening in the Mac's browser outside Yardlet (`OutsideBrowser`), the location, and
  the first lines of the notes.
- **Hand to an agent…** starts a chat whose composer names the event: its title and time, its account, calendar and
  event ID, and the connector's tool that reads it (`calendar_get_event` for Google Calendar, which takes the
  account's address). The notes are not put in the prompt; the agent reads them with the tool, and the person writes
  what to do.
- **Open in Google Calendar** or **Open in Outlook** opens the event on the service's web app in the Mac's browser
  outside Yardlet; a Mac event offers **Open in Calendar**.

## On the desk

The home's desk (its Now view, shown while the development switch `YardletDeskPreview` is on) takes today from the
calendar while the calendar is on.

- While the desk shows, it asks the calendar to read today (`DeskProjection.today`), under the same rules as a window
  showing the calendar: the day held by a range already read is not read again, and nothing is read once the desk goes,
  for the Projects view, another screen or a closed window.
- **Today** lists today's events with the scheduled runs in time order: all-day events first, then each event's time,
  its calendar's color, its title, and whether it ended, is under way or starts soon ("in 1 hour"). An invitation not
  answered yet says "Not replied", kept when the line is too narrow for the rest. The header's and the zone's count of
  what is left today counts the runs to come and the timed events that have not ended.
- With the calendar on and the home at least 1,200 points wide (`DeskLayout.zones`), the desk stands as three zones:
  what waits, what runs and just finished, and today on a time axis (`DeskTimeAxis`). Unread mail folds to one line
  above it and all-day events stay lines. The axis spans 9:00 to 23:00, widened to today's earliest and latest items;
  events sit at their times in their calendars' colors, side by side where they overlap; an invitation not answered
  yet is outlined dashed; runs are dashed with a clock; a red line marks the time now. A column too short for it
  scrolls, opening at the time now.
- Choosing an event shows it on the calendar, chosen; choosing a run opens its scheduled task. The keyboard goes
  through today's lines after the desk's other lines.
- The axis is drawn again only when what it shows changes, to the minute, so the time line moving draws no other part
  of the desk.

## Not included

- Creating, moving or editing events on the screen or the desk. Agents do these with the calendar connectors' tools
  (docs/CONNECTORS.md, "Tools").
- A month view, search, and notifications of events.
- Answering invitations of Apple Calendar events.

## Code

| Location | Contents |
|---|---|
| `Domain/Calendar.swift` | Accounts, calendars, events, invitation answers, failures, and the transport contract (`CalendarAccountTransport`) |
| `Connectors/GoogleCalendarTransport.swift` | Calendar API v3 requests shared with the Google Calendar tools (`GoogleCalendarAPI`), and the contract over them |
| `Connectors/OutlookCalendarTransport.swift` | Graph requests shared with the Outlook Calendar tools (`OutlookCalendarAPI`), and the contract over them |
| `Connectors/MacCalendarTransport.swift` | The Mac's calendars through `MacDataStoring` |
| `Presentation/CalendarCenter.swift` | The app's calendar: accounts, what is read and kept, the Mac's copies, choices and answers |
| `Presentation/CalendarWindowState.swift` | A window's days and chosen event, scheduled runs on the days, laying out events that overlap, and dates and the hand-off text (`CalendarText`) |
| `AppModel+Calendar.swift` | Following the setting and the connectors |
| `Presentation/DeskProjection.swift`, `Views/AppShell/DeskHome.swift`, `Views/AppShell/DeskTimeAxis.swift` | The desk's today: its events, what is left, the three zones and the time axis |
| `Views/Calendar/` | The sidebar (`CalendarSidebar`), the days (`CalendarWorkspace`, `CalendarDaysView`) and an event (`CalendarEventDetail`) |

Tests: `GoogleConnectorTests` and `MicrosoftConnectorTests` (the transports against a fake Google and a fake Graph),
`CalendarCenterTests` (one calendar reached two ways, the Mac's copy standing in, reading only what is shown and not
again within five minutes, forgetting when turned off, answering an invitation on its own service) and
`CalendarRenderingTests` (the sidebar's words, the week, an event, an answer, the hand-off and the day, with nothing
read before the calendar shows or after it goes, drawn under `.build/calendar-qa/` in both appearances at 1280×820 and
1800×1125), and `NewTaskHomeRenderingTests` (the desk's three zones, two columns with the calendar off and in a
narrower home, reading today only while the desk shows, and the time axis alone drawn again as the minute changes,
drawn under `.build/desk-qa/`).
