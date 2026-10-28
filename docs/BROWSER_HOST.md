# In-window browser (macOS browser host)

Written: 2026-09-28. The Windows design is [WINDOWS_BROWSER_HOST](WINDOWS_BROWSER_HOST.md). This document is the
operating document for the macOS product implementation.

## 1. Overview

- Each task (session) has up to 9 browser tabs (one before 2026-10-22). Each browser tab is a tab of the side panel on
  the right (2026-10-23; before that, a tab strip inside the single panel tab "Browser"), and the browser tab the panel
  shows is the front tab. The agent drives the same tabs through CDP and uses its active tab (usually the front tab)
  when it gives no `tabId`; it does not change the tab the person is using in the panel (section 3, "Tabs" and "The tab
  the person uses", and section 6).
- What a page makes the person deal with (a JS dialog, a file chooser, a passkey or sign-in window, a permission or
  another-app question, a handoff) waits in its tab and shows over the panel that shows that tab. Meanwhile the task's
  row, a mark on the panel tab and one notification say so (section 3, "Tabs that wait on the person", 2026-10-27).
- Chromium (CEF) runs in a **browser host process** outside Yardlet. The Yardlet executable has no CEF. The host draws
  without a window (off-screen rendering) and hands frames to Yardlet as IOSurfaces, and the Yardlet panel sends input
  to the host.
- When the host ends, all of Chromium's processes and memory go away (only Chromium's copy-cleanup Helper stays a few
  tens of ms longer to delete the temporary copy; section 3, "Shutdown"). A task's tabs stay until the task is archived
  or deleted (as the Codex app cleans up browser pages when it archives a thread), and the host ends 60 seconds after no
  tab is left open.
- A tab hidden for more than 4 hours is discarded, as Chrome's Memory Saver discards one: its renderer ends, while its
  address, title, icon, place and back/forward history stay, and its page loads again when it is shown or the agent uses
  it. While memory is critical, tabs hidden for more than 10 minutes go, one every 5 seconds (section 3, "Memory saver";
  Settings › General "Memory saver").
- VoiceOver and accessibility apps read and operate the page in the panel element by element. The page's accessibility
  tree is turned on only when something asks for it (section 5).
- In Yardlet built without CEF (`swift build`, `swift run`, `swift test`), the browser panel falls back to the existing
  WebKit preview.

## 2. Structure

```text
Yardlet.app
├── Contents/MacOS/Yardlet                                panel, transport, lifetime management (no CEF)
└── Contents/Frameworks/Yardlet Browser Host.app          CEF's main bundle, LSUIElement
    ├── Contents/MacOS/Yardlet Browser Host               Swift + CEF C API, NSApplication subclass
    └── Contents/Frameworks/
        ├── Chromium Embedded Framework.framework         Versions/A layout, locales en and ko only
        └── Yardlet Helper{, (Alerts), (GPU), (Plugin), (Renderer)}.app   LSUIElement, sandbox
```

| Layer | Location | Contents |
|---|---|---|
| Engine (shared across platforms, Foundation only) | `Sources/NativeHarnessClient/BrowserHost/` | `BrowserHostProtocol` (commands and events), `BrowserHostFraming`, `BrowserHostClient` (lifetime, tabs, visibility), `BrowserTab`, `BrowserDevToolsClient` (CDP), `BrowserURLPolicy`, `BrowserAccessibilityTree` (accessibility tree), `BrowserFrameSurfaceCache` (how long received frame surfaces are held) |
| macOS layer | `Sources/NativeHarnessClient/Platform/macOS/BrowserHost/` | `CEFBrowserHostProcess` (process, pipes, IOSurface receiving), `MacBrowserHost` (the app's single client), `BrowserHostView` (layers, input, IME, drag and drop, menus), `BrowserSecureInput` (secure input and input source limits for password fields), `BrowserHostPane` (SwiftUI panel), `BrowserKeyCodes`, `BrowserAccessibilityBridge` and `BrowserAccessibilityElement` (VoiceOver) |
| Mach exchange | `Sources/YardletSurfacePort/` | bootstrap check-in/look-up, sending and receiving IOSurface ports, audit token checks (C) |
| CEF accessibility processing | `Sources/YardletCEFAccessibility/` | `CEFAccessibilityReducer`: CEF accessibility values → the contract's small shape. It uses only Foundation, so it is tested without CEF |
| Host | `Sources/YardletBrowserHost/`, `Sources/YardletCEFBridge/`, `Sources/YardletCEFHelper/` | CEF initialization and handlers, frame copying, command handling, accessibility forwarding (`AccessibilityForwarder`), the renderer's password field notices (`FocusedField.c`). Compiled only when `YARDLET_CEF_DIR` is set |

Transport is a 4-byte length + JSON over the host's standard input (commands) and standard output (events). The JSON is
Swift Codable's default form `{"<case>": {<fields>}}`, and `BrowserHostProtocolTests` pins its shape. As soon as it
starts, the host redirects standard output to standard error so that text Chromium prints cannot break the event stream.
When Yardlet dies and standard input ends, the host ends too. Yardlet does event framing and JSON decoding on the pipe's
serial queue and hands only the decoded events, in order, to the main thread.

**Frame display does not go through the main thread (2026-10-22).** The same pipe queue takes the frame event's
IOSurface from the Mach port (`BrowserSurfaceReceiver`) and puts it straight into the layer of the panel showing that
tab (`BrowserFrameDisplay`, the panel view's `contentLayer`) in an explicit `CATransaction`. `BrowserFrameRouter` (one
lock) holds which panel shows which tab, and the main thread changes it when a panel attaches or detaches a tab
(`MacBrowserHost.showFrames(of:in:)` and `stopShowingFrames`). The main thread still receives frame events (for the
agent tools' observers and others), but they are already on screen, so while the main thread is busy a newer frame of
the same tab replaces the earlier one (`BrowserMainThreadEvents`: one frame per tab per delivery, the order of other
events unchanged). The main thread places only the popup layer (`<select>` lists) and frames not yet on screen. Before
this, each frame waited for its turn on the main thread and queued behind SwiftUI window updates (28 times a second per
window while a task streams, about 17 ms each). Input still goes through the main thread, because AppKit delivers it
there.

**Previews in the session rail (2026-10-22).** For each tab the router holds one preview (`setPreview`) besides the one
panel, and puts the same frame into that layer too, on the same pipe queue (`route`). The preview layer does not change
size; it fits the frame with `contentsGravity` (`BrowserFrameDisplay(sizesLayer: false)`, `BrowserFramePreviewView`). So
that a preview attached late shows at once, the router holds the tab's last frame (`latestFrame`) and lets it go on the
host's `hidden` and `closed`: the router does not hold on to a hidden tab's surface. A preview does not make the tab
visible to the engine: it draws only the frames drawn while the agent uses the tab (`agentVisibleWindow`), and after
that the last frame stays in the preview layer (the card goes away when the turn ends). The tab to preview is the one
the agent used (`BrowserHostClient.onAgentActivity` → `BrowserAgentUse`), cleared at the end of the turn, when the tab
closes (`onTabClosed`) and when the host ends.

The host receives CEF shared textures (`on_accelerated_paint`, IOSurface) (`acceleratedPaint: true` in `.ready`).
`copies` in the stats line is not a CPU copy but a Metal blit (GPU) that moves that texture into the host's IOSurface
ring. Under CEF's contract the texture comes from a pool and goes back to it when the callback ends ("cannot be cached
and cannot be accessed outside of this callback"), so it has to be copied before it is handed on.

## 3. Decisions

| Item | Decision |
|---|---|
| Host lifetime | Session tabs are not closed when the panel closes or the agent stops; they stay until the task is archived or deleted and its tabs are closed (the Codex app cleans up the browser conversation on `thread/archived`, and pages that are not visible only get background throttling). A tab that is not visible is reported to the engine as hidden, which stops drawing. When the last tab closes, the host ends 60 seconds later (`idleGrace`). Opening the panel again shows the same tab (with the page state as it was). After the host has died, the task's tabs open again together at the addresses they last showed (`rememberedTabs(forSession:)`, including order and the front tab) (`restoreTabs`), and the agent tools open the same tabs again. Failing that, they open at the addresses saved with the task (the list when there are several tabs, `BrowserPreviewPreferences.tabs` and `selectedTab`, after the app restarts). Closing the task's tabs (`closeTabs(forSession:)`) forgets the addresses. Before 2026-10-22, tabs without a panel were closed after 5 minutes (`agentKeepAlive`) + 60 seconds, so a page the agent opened became an empty tab before the user opened the panel |
| Shutdown | 2026-10-24. End of input (Yardlet ended), the `shutdown` command and SIGTERM all end in the order CEF recommends: close every open browser with `close_browser(force)`, end the message loop after the last `on_before_close` (or after 3 seconds if it does not come), then `exit(0)` after `CefShutdown` (`BrowserHost.shutdown`). With CEF's signal handlers turned off (`disable_signal_handlers`), the host catches SIGTERM and follows this order. The handler is an empty function, not SIG_IGN: an ignored signal is inherited by Chromium's child processes, and Chromium ends its child processes with SIGTERM. SIGPIPE is ignored so that writing an event after Yardlet has ended fails with EPIPE. If it has not ended within 10 seconds (`shutdownDeadline`), the host ends its own process group with SIGKILL (a host started by `Process` leads its own group, and Chromium's child processes are in the same group). When the app quits (`terminateHost`), Yardlet sends `shutdown`, waits up to 5 seconds (`shutdownTimeout`) for the host to end, and ends it with SIGKILL after that (`terminate()`). Shutdown after the grace period (`shutdownHost`) does the same after 5 seconds. `CefShutdown` starts Chromium's code-sign clone cleanup Helper (`--type=code-sign-clone-cleanup`) in a new process group; that Helper waits for the host to end (`getppid() == 1`) and then deletes the bundle copy the host made when it started (section 8). CEF does not pass `--framework-dir-path` or `--main-bundle-path` to this Helper, so the Helper executable (`YardletCEFHelper/main.c`) fills the missing switches with the host bundle's path. Without that, CEF took the outermost `.app` in the executable path (Yardlet.app) as the main bundle, could not find the framework and ended with a CHECK (SIGTRAP), so every orderly shutdown left a crash report and copies piled up. Before 2026-10-24, app quit and the end of QA sent SIGTERM right after `shutdown`, so the host ended without `CefShutdown`, and when Yardlet ended abruptly the host died of SIGPIPE. When the host ends with SIGKILL, its child processes end on their own when IPC breaks (0 left in QA), and only that host's copy remains. The `closed` the host sends for each tab as it ends does not mean the page closed: Yardlet does not accept a `closed` that comes after it sent `shutdown` (`isHostEnding`), and on `terminated` the tab stays as a tab lost with the host (`rememberedTabs`, with its panel tab and saved state unchanged). From the change above on 2026-10-24 until the fix on 2026-10-25, this `closed` was taken as the page closing, so on app quit the tabs open in the engine dropped out of the panel and the task's saved state (after a restart the task had no browser tabs, and a panel that held only those tabs was closed). Before that, SIGTERM ended the host at once, so `closed` almost never came |
| Full-page screenshots | 2026-10-24. Chromium handles `captureBeyondViewport` in `Page.captureScreenshot` by briefly growing the view to the capture size (`PageHandler::CaptureScreenshot` calls the view's `SetSize`), but in CEF's windowless view `SetSize` and `SetBounds` are empty functions (`render_widget_host_view_osr.cc`), so the surface stayed at the panel's size and the image repeated the first screen at every multiple of that height (reproduced in QA, every 800 px). So `fullPage` in `browser_screenshot` draws the tab at the capture size while it captures (`BrowserAgentTools.drawn`): it pins the page's layout viewport at the current size (the view's whole points) with `Emulation.setDeviceMetricsOverride`, `resize`s the tab to the capture size, and after the capture first restores the tab's size and then removes the pin. Commands go in order over the same pipe, so there is nothing to wait for. Meanwhile 100vh and `innerHeight` stay the same, and the page gets only the one `resize` event that Chromium's capture itself fires. The surface is a GPU texture, so when a side went over 16,384 device pixels the GPU process kept dying with `Invalid size=2560x20352, max_texture…`, the host ended with `GPU process isn't usable. Goodbye.`, and every tab was lost (confirmed with a 10,176 CSS px page at 2x). So the capture is cut within that limit and takes the top part (8,190 CSS px at 2x). If the panel is showing that tab, the large frames in between reach the panel, so the panel view clips to its own bounds (`clipsToBounds`). Element (`ref`) screenshots are still taken only within the view |
| Screen size emulation | 2026-10-26. The person (Viewport in the panel's ⋯ menu) and the agent (`browser_resize`) view a tab's page as a 375×812 phone, a 768×1024 tablet, 1280 × 800, 1024 × 768 or a custom size (the same presets and rules as the Claude app's Browser window). `BrowserTab.emulate` sends `Emulation.setDeviceMetricsOverride` (scale 1; below 768 wide, mobile and deviceScaleFactor 2), `setTouchEmulationEnabled` and `setUserAgentOverride`, and draws the tab itself at that size: when a panel shows the tab, the panel view sends the emulated size with `resize` (`BrowserHostView.emulatedSize`); without a panel the tab sends it, and removing the emulation returns to the earlier size. The panel shrinks the layer holding that frame (`pageLayer`) until both sides fit and places it centered horizontally at the top (`BrowserViewportEmulation.pageFrame`), with `underPageBackgroundColor` and a 1-point divider outside it. It does not shrink with Chromium's `scale` because that factor is not reflected in CDP `Input.dispatchMouseEvent` coordinates, so the agent's clicks would miss (in headless Chrome 155 at 0.5x, the page received doubled coordinates). The DevTools session carries the emulation, so it survives new loads. The state lives only in the tab, so when the host starts again the page is responsive again. What the agent set is cleared when its turn ends (`endAgentEmulation`) |
| Cross-site frames | 2026-10-26. An iframe that site isolation puts in another renderer can be read only through its own session attached to the tab's DevTools session. When the agent tools first use a tab, `BrowserDevToolsClient.attachFrames()` sends `Target.setAutoAttach` (flatten, `filter` iframes only, `waitForDebuggerOnStart` false), and sends the same request to each attached frame so nested frames attach too. `frameSessions` follows `Target.attachedToTarget` and `detachedFromTarget` (removing a detached frame's descendants with it); events from frame sessions do not go into the tab's event log or its observers, and timeouts of those calls do not count as the tab not responding |
| Drawing (power) | A session tab is "visible" to the engine only while a panel **on screen** shows it and for 60 seconds (`agentVisibleWindow`) after the agent uses (or opens) it. Otherwise it is hidden with `was_hidden`, which stops frames and slows the page's timers (QA: an animation page, 63 fps → 0 over 2 seconds). Even with a panel attached, if the window is minimized, fully covered by other windows, on another Space, or the app is hidden (⌘H) (`NSWindow.occlusionState` without `.visible`, `BrowserHostView.isOccluded`), the panel reports itself "occluded" (`setPanelOccluded`) and the tab is hidden. The tab stays attached (its lifetime depends on the number of panels), and when it is visible again it gets a new frame through `invalidate` (2026-10-22 QA: in a minimized window, 60 fps and about 40% total CPU → 0 fps and about 2%). The rule that keeps a tab visible for 60 seconds after it opens applies only to tabs opened without a panel (the agent's tabs). A tab a panel has shown even once is visible only after the agent uses it, so a tab the panel opened hides as soon as the window is covered (fixed on 2026-10-22: this rule used to keep drawing a covered tab opened less than 60 seconds earlier). Attaching a panel or the agent using the tab again makes it visible before the next command |
| Frame rate | The panel sends the refresh rate of the display its window is on (`NSScreen.maximumFramesPerSecond`) as the viewport's `framesPerSecond` (whenever the size, scale or display changes), and the host matches it with `set_windowless_frame_rate`: 120 on the built-in ProMotion display, 60 on an external LG. A tab without a panel (`offscreenDefault`) defaults to 60. requestAnimationFrame animations reach 120 fps on a 120 Hz screen (QA). Wheel and key scrolling stay at 60 fps whatever the input rate; this looks like a scroll frame limit on Chromium's side, and the cause is not found yet (section 10) |
| Frame surface lifetime | The host cycles through up to 4 IOSurfaces of the same size for each of a tab's layers (view and popup) (`SurfaceRing`). When the size changes it makes a new ring; when the tab is hidden (`visibility` isHidden) it drops the ring and then sends a `hidden` event; when the tab closes it drops the ring. Whether a surface's port has been sent is remembered for each surface in the ring (the earlier global set of IDs did not send the port again when an ID was reused, so Yardlet waited 200 ms at a time and lost frames: in 2026-10-22 QA, 26 of 40 size changes did not get a frame at the new size within 600 ms → 0). On the event pipe queue, in event order (`BrowserFrameSurfaceCache` inside `BrowserSurfaceReceiver`), Yardlet drops surfaces of a different size in the same tab and layer, and old surfaces beyond the ring's capacity (4), as frames arrive, and drops all of a tab's (or layer's) surfaces on `hidden`, `closed` and popup-closed events. So a hidden tab uses no surface memory (QA: host footprint after 40 size changes +81 MiB → +9 MiB, after hiding 220 → 75 MiB). If the port of the surface a frame names is missing, Yardlet drops that frame without waiting. The host writes the frame event after sending the port, so a port that is missing when the event is read is not coming (it used to wait 200 ms each time) |
| Frames during a resize | 2026-10-27. While the panel's width was dragged, the page shrank and grew instead of following the new width. Chromium's capture (`FrameSinkVideoCapturer`) changes the frame size only after the page has drawn at the new size (CEF `OnRenderFrameMetadataChangedAfterActivation` → `SizeChanged`), while the root of the view, the capture source, takes the new size as soon as `was_resized` is called. Frames in between fit the new-size source into the old size, keeping its proportions, and fill the rest with black bars (`content_rect` smaller than the frame; about 8 px left and right when narrowing, about 17 px top and bottom when widening). In the drag QA, 136 such frames came over 202 size changes. The bridge (`is_resize_letterbox`) does not send such screen frames within 1 second after a size or scale change, and the panel keeps the previous frame. A difference that remains after 1 second (when the page is held at a size other than the view's, as in the agent's full-page screenshot) shows as before. For software drawing (`--paint software`) CEF gives no `content_rect`, so nothing is filtered |
| Tabs | Each task has up to 9 tabs (`maxTabsPerSession`) in strip order, one of which is the front tab (Claude app 3.1623.3 Browser window: "Tab limit reached" past 8 tabs, ⌘1…⌘9). Since 2026-10-23 each tab is a tab of the side panel (`browser:<key>`) (Codex app 26.1016). Each tab has a panel key (`BrowserTab.key`), and it opens again with the same key when the tab moves to another task, the host dies or Yardlet restarts. The panel and the engine refer to the same tab by this key (`TaskWorkspaceState.syncBrowserTabs`): a tab the engine opened (the agent's or a page's) becomes a panel tab placed after the tab just before it in the engine, and a tab the engine closed while the host is running drops out of the panel too (tabs closed as the host ends do not drop out; see "Shutdown" above). The browser tab the panel shows is the front tab (`frontShownBrowserTab` → `BrowserHostClient.show`), and when the engine changes the front tab (the agent's selection, a new window opened in front), the panel that was showing a browser tab shows that tab, unless the person is using another of the task's tabs in the panel (2026-10-27, "The tab the person uses" below). A new panel tab ("Browser" in the launcher and the + menu, ⌘T on a page, "New Tab to the Right" and "Duplicate" in the tab menu, a link in the conversation) opens an engine tab once its pane is visible (`openBrowserEngineTab`; with no address, an empty tab with focus in the address field). A panel tab has the page title, icon (see "Icons" below) and a loading spinner; there is no tab strip inside the browser pane. Closing a tab in the panel closes its page (closes the engine tab), and the panel goes to the tab used before it, as with other panel tabs; the panel closes only when all its panel tabs are closed. When the front tab closes in the engine, the tab that moves into its place comes to the front, or the one before it if there is none (Chrome). Up to 10 closed tab addresses per task reopen in a new panel tab with ⌘⇧T. When the panel switches the tab it shows, the pane's frame route (`BrowserFrameRouter`), accessibility and event handlers move to the new tab (the pane stays, so keyboard focus stays), and the tab that was in front is reported to the engine as hidden (if the agent used it within 60 seconds it stays visible for that time, as in the Claude app: "Background tabs keep running while you drive them"). Saved: each tab's key, address and title (`BrowserPreviewPreferences.pages`). When the task state is first read and the engine has neither open nor lost tabs, the saved tabs are passed to `rememberTabs` and reopen together when the panel shows one of them or the agent first uses them (`restoreTabs`). On 2026-10-22 and 2026-10-23 there was a Claude-app-style tab strip (with two or more tabs, + and ⌘T) inside the single panel tab "Browser", and closing the last tab closed the panel. For new windows a page asks for, see "New windows" below |
| Number of tabs | 2026-10-27. One browser host holds the tabs of every task, and the pop-ups of their pages, as browsers. The bridge's browser table (`kMaximumBrowsers`) has 256 slots, and the request context table 32 more than that. Before, they had 16 and 32 slots. With 16 slots, once the tabs of several tasks filled 16, no browser was created for a new tab in any task (`yardlet_cef_create_browser` returned 0). The host sent `failed` for that tab, but the app kept it as an open, empty tab. So every agent call ended with "The browser tab is gone.", and the tab list showed about:blank as "responding". The panel reported it only if it was showing that tab when the failure came (installed app from 2026-10-27 03:05, host 17207: 16 made up of tabs 1–10 and 12–16 and one pop-up whose renderer had died). It showed only in tasks whose panel was closed because those tasks lost their tabs when the host restarted at 01:13 and made new tabs only after the slots were full. Tabs already open stayed normal throughout. Now, when the slots are full, `create_browser` returns -1, and the host tells only that tab with `failed(message:tab:limit:)` and writes `tab not opened tab=… reason=limit` to host.log. If Chromium cannot create the browser it is `reason=chromium`, and if the profile is not read within 20 seconds the host gives up on the tab (`yardlet_cef_cancel_waiting_browser`) with `reason=profile`. DevTools calls waiting for that tab are answered at once with that reason. The app remembers the tab as `BrowserTab.openFailure`. That tab's DevTools calls fail at once without going to the host, the agent tools fail at once with that one reason ("This tab could not open: …"), and the tab list adds "Could not open: tab …". `browser_navigate` opens the tab anew as the same panel tab (the same `replace` as for a tab that is not responding). When the panel shows the tab (even if it shows it only after the failure), it shows "The browser has too many tabs open. Close a tab in this or another task, then try again." (for another reason, "This tab could not open: ‹reason›") on the "Page unavailable" card. "Try again", reloading and entering an address open the tab again in its place (only that tab, like Chrome's error page and reload). Verified by the QA `many-tabs` in section 11 |
| New windows | 2026-10-25. When a page's request for a new window (`window.open`, `target=_blank`, a click with a modifier key) comes with a user gesture, the host lets CEF create a windowless browser in `on_before_popup`. Like a Chrome pop-up, that browser has `window.opener` and the opening tab's request context (the task profile). The host reserves an empty slot and gives that slot's client the opening tab's size, scale and frame rate, and when CEF creates the browser (`on_after_created`; if the render handler's question comes first, it finds the reservation with `get_opener_identifier`), the host assigns a tab number (from 2^30; tabs Yardlet opens start at 1) and sends `popupOpened(tab:opener:url:background:)`. Yardlet takes the tab as a task tab of the opening tab (`adoptPopup`: at the end of the strip; behind for a background-tab click, otherwise in front). For a tab outside any task, or a task that has 9 tabs, it closes that browser and the opening tab goes to the address. Without a user gesture, or when the browser slots are full (see "Number of tabs" above), the host reports `newWindow` as before, and Yardlet does not open requests without a gesture (as Chrome's pop-up blocking does). But before the evening of 2026-10-25, requests without a gesture never got this far: CEF's `CanCreateWindow` calls the Chrome layer (`ChromeContentBrowserClient::CanCreateWindow`) first, and Chrome's pop-up blocker (`blocked_content::MaybeBlockPopup`, `kNoGesture` in `ShouldBlockPopup`) put the blocked request into `PopupBlockerTabHelper`, which serves Chrome's address bar, so in a windowless tab no one ever saw that list (reproduced in QA: 0 entries). So the browser process starts with Chrome's own switch `--disable-popup-blocking`, and the host's `on_before_popup` keeps the same rule (no user gesture). Nothing is left in the profile. From then on, the address stays in the list of an indicator at the right of the panel's address field (a crossed-out window, with the help text "Pop-ups were blocked on this page."), like "Pop-ups blocked" in Chrome's address bar (`BrowserTab.blockedPopups`, the first 25 as in Chrome, `kMaximumNumberOfPopups`), and when the person picks it, it opens in front as a new task tab (`BrowserHostClient.openBlockedPopup`). The engine did not create that window, so the tab has no `window.opener` (Chrome holds on to the blocked request and opens it with its opener). The list is cleared when the page changes to a new document (`newDocument`: the main frame in CEF's `on_load_start`, which does not come for navigation within the same document; Chrome's `PopupBlockerTabHelper::DidFinishNavigation`). The agent tools report the blocked pop-up addresses at the end of a result (the agent opens such an address with `browser_tab_new`). Chrome's "Always allow pop-ups from this site" is not included. If creation fails (`on_before_popup_aborted`), the reservation is released. When a pop-up calls `window.close()`, its tab drops out on `closed`, and the panel goes to the tab used before it. So a card issuer's 3-D Secure window, PayPal or a sign-in pop-up can answer the page that opened it through `window.opener.postMessage` (QA `checkout`). Window size requests (`width` and `height`) are not used; the window opens as a tab. From 2026-10-22 to 2026-10-25 the host cancelled every new window and Yardlet opened its address in a new tab without `window.opener`; before that it opened in the opening tab. The two apps (bundle bytes): the Claude app 3.1623.3 takes only pop-ups given a size into tabs, as windows Electron created, keeping the opener, and opens `target=_blank` in the opening tab; the Codex app 26.1016 takes only `target=_blank` that way and opens pop-ups given a size in a new tab without an opener |
| Moving tabs | Tabs on the new-task screen belong to the draft's workspace ID (`TaskWorkspaceStore.draftID`), and when the task sent from that screen is created, they move to that task one tab at a time (`move(_:toSession:select:)`, `moveTabs(fromSession:toSession:)`, 2026-10-23). Only the client's ownership changes (`BrowserTab.session`, strip order, front tab) and nothing is sent to the host, so the pages and their state stay as they are. The tab keys stay too, so the panel tabs the task takes over are the same tabs. Moved tabs do not go into the closed-tab list; they are appended in the same strip order, and the draft's front tab becomes the task's front tab. Tabs are not moved into a task that has 9 tabs. Tab addresses the draft lost when the host died (`rememberedTabs`) are handed to the task too. QA: `--ui-fixture-browser-check-only=draft-handoff` |
| Icons | 2026-10-23. When CEF reports the page's icon addresses (`on_favicon_urlchange`), the host downloads the first one with `download_image` (as a favicon, so it neither sends nor receives cookies; 16 DIP, up to 2x) through the browser's own network and cache, and sends the PNG from `get_as_png(2.0)` in a `favicon(tab:url:png:)` event (empty data if the download fails). Each download gets its own callback that knows its tab, freed when its reference count reaches 0. Yardlet keeps the icon in `BrowserTab.favicon` and calls the tab observers, and clears it when the address changes to another host (site). It is not saved |
| Page errors | 2026-10-23. "Unavailable" in the panel header and the error card attach only to the visible tab, and only to the navigation that failed. A main-frame `loadError` (except -3 `ERR_ABORTED`) becomes a card when its address commits: an `address` to that address, or the `loadEnd` with status 0 that Chromium sends for the error page (CEF 154 sends no address change for an error page; QA `load-errors`). If loading ends without a commit (the previous page stays), there is a "Could not open ‹address›." notice instead of a card. An error that comes after loading has ended belongs to a navigation already replaced, so it is dropped. The card is cleared by a commit of another address (`address`, including history.pushState) or by a `loadEnd` with an HTTP status (a reload succeeded), and stays through the error page's own follow-up loading (`loading` → -3 → end) (before 2026-10-23 that loading cleared real failures). Showing another tab clears it. The host's `failed` carries a tab (`failed(message:tab:)`, a tab whose browser could not be created) and goes only to that tab; only a `failed` without a tab goes to every tab. A tab that could not receive a CDP message (an agent call to a tab that is gone) gets a DevTools error answer (-32001) for that call's `id` instead of `failed`, so the call fails at once. Before 2026-10-23 this went to every tab as a `failed` without a tab, and healthy pages showed "Unavailable" and the card (reproduced in QA). Diagnostics: for each main-frame load error the host writes one line to host.log, `load error tab=… code=… host=…` (host name only, no path or query), and one line `devtools message refused tab=…` |
| Not responding | 2026-10-23. A tab's page is not responding when one of two facts holds: Chromium's hang monitor finds that the renderer has not handled input for 15 seconds, or a DevTools call the renderer answers (the navigation calls `Page.navigate`, `reload` and `navigateToHistoryEntry`, and every call outside `Target.` and `Browser.`) got no answer in time (`BrowserTab.unresponsive`: `.hangMonitor` and `.unanswered(method:)`). Chromium does not call `OnRenderProcessUnresponsive` for a tab with a DevTools session attached (Yardlet's tabs have one, for the agent and accessibility) (`IsDebuggerAttached` in `WebContentsImpl::RendererUnresponsive`; confirmed in QA, where only "responsive" ever came), so the host reads `is_render_process_unresponsive` for each open tab every second and sends `responsiveness(tab:isResponsive:)` when it changes. For a tab where the callback does come, the host holds on to that callback (wait and terminate in the `unresponsive(tab:action:)` command). The panel shows Chrome's "Page Unresponsive" bar with "Wait" and "Reload", and the header status is one line: "Not responding" > "Crashed" (see "Renderer exit" below) > "Unavailable" > "Loading" > "Ready" (the error card is hidden while the page is not responding). Wait hides the bar for 15 seconds and shows it again if the page still does not respond (Chrome's Wait). Reload, and the agent's `browser_navigate` to a tab that is not responding, open the tab anew with the same key, position and front state (`BrowserHostClient.replace`: if a callback is held, it ends the renderer first, then closes and opens). QA (`unresponsive`): the renderer of a script that never ends was at 98–100% CPU and was gone after the replacement. The state clears when the page responds (`responsiveness` true), when the renderer ends (`pageCrashed`) or when an answer comes to a call the renderer answers. The host log has `renderer unresponsive|responsive tab=…` |
| Renderer exit | 2026-10-24. When a renderer ends (CEF `on_render_process_terminated`), the host writes one line to host.log, `renderer ended tab=… status=… code=…` (`status` is crashed, oom, killed, abnormal and so on; `code` is the exit code, the signal number for a crash), and sends `pageCrashed(tab:reason:status:code:)`. `reason` is the error code of Chrome's error screen, named by the host (SIGTRAP, SIGSEGV and so on, Out of Memory; signal numbers differ by platform, so the host names them, not the engine). The tab keeps `BrowserTab.crash` (`BrowserTabCrash`) until the next load starts. The panel gets the header status "Crashed" and a card in the Codex app's wording ("This page crashed", "‹host› ended unexpectedly. Error code: ‹code›", Reload), and the agent tools get the fact at the end of a result ("This tab's page crashed: its renderer ended (error code ‹code›). …") and a line "Crashed: tab … (‹code›)" in `browser_tab_list`. All five crashes in the installed app were caused by input timestamps (section 4, "Input timestamps") |
| Memory saver | 2026-10-27. As Chrome's Memory Saver does, a task's tab hidden from its engine (no panel shows it on screen and the
agent has not used it for a minute) for 4 hours is discarded. The figures are Chromium's source: its recommended Balanced mode
(`MemorySaverModePolicy`, kMedium) is 4 hours, and the hidden time leaves out the Mac's sleep (`SuspendingClock`, Chrome's
elapsed_not_suspended). While macOS memory pressure is critical, as Chrome's urgent discarding (`UrgentPageDiscardingPolicy`)
one tab goes every 5 seconds, the longest hidden first among those hidden for more than 10 minutes
(kNonVisiblePagesUrgentProtectionTime). At the warning level Chrome discards nothing either. The tabs kept follow
`DiscardEligibilityPolicy`: a tab a panel shows (an occluded panel too, as Chrome keeps each window's front tab); a page
loading, whose renderer ended or does not respond; a page playing sound (Chrome keeps it until a minute after the sound
stops, kTabAudioProtectionTime; Yardlet, for the reason below, once the page has played sound in its current document); the
camera or microphone in use; a form typed into (a field whose value differs from the one the page loaded with, or a
document the person typed in); a download under way; a permission bar, JavaScript dialog, file chooser, question to open
another app or leave-page question; one of Chromium's windows over the tab (passkey, HTTP authentication); a handoff
(`browser_handoff`); a tab the agent used in its turn that is still going; a page not on http, https or data; a PDF; and the
result of a form submission (POST, which a reload would send again). Except under urgent discarding, a site allowed to show
notifications and a page whose title or icon changed while hidden (a chat's unread count, kBackgroundActivity) are kept too.
Chrome's "Always keep these sites active" list, pinned tabs and USB or Bluetooth devices do not exist for Yardlet's tabs.
**How:** CEF 154 has no discard of its own, so the host ends the tab's main-frame renderer the way Chrome's task manager
ends a process (`cef_task_manager_t`'s `kill_task`; the task manager is made for that call only, since while it lives it
measures every process every two seconds). The CEF browser and its navigation entries stay, and when the tab is shown or the
agent uses it a reload reads the page again in a new renderer (Chrome too reloads a discarded tab it shows). Closing the
browser and opening its address again was not used: it loses the back/forward history. Before the end, the host
(`TabDiscarder`) (1) reads what the browser process knows (`yardlet_cef_page_signals`: loading, camera or microphone, when
the page last began to play sound, POST, a PDF frame, the notification permission) and (2) asks every frame of the tab
(`YardletPageStateQuery`; the helper's `PageState.c` runs a read-only expression in the frame's V8 context). The answers say
whether media plays out loud, whether a form field changed, whether the frame has media elements, and whether the main
frame's renderer also holds another tab's frames (the renderer counts the browser objects CEF tells it of,
`OnBrowserCreated` and `OnBrowserDestroyed`, one by one: CEF makes one per page and may make a tab's next before its last
goes). Chromium may keep same-site pages, pop-ups and iframes of one profile in one renderer, and ending it would end the
other tab too, so such a tab is kept. A frame that does not answer within 3 seconds also keeps the tab. Once every frame
answered and nothing keeps the page, the main frame alone is asked once more (`yardlet_cef_ask_main_frame`) whether another
tab's page or iframe came into its renderer meanwhile, and the renderer ends on that answer. If the page opens a dialog,
file chooser, permission bar, question to open another app or a download, or one of Chromium's windows appears meanwhile,
the discard is dropped (`BrowserHost.keepTabsAskingThePerson`). A limit left: SharedWorkers and ServiceWorkers are not
browsers and are not counted, so another tab using a SharedWorker in that renderer loses its connection (a ServiceWorker
starts again at its next request). CEF does not say whether a page plays sound. Instead, each time a page begins to play
sound, it asks the audio handler for capture parameters (`get_audio_parameters`); the host notes the time and declines
(accepting would mute the tab: CEF's loopback capture passes `mute_source`). When the sound stops is not known, and audio not
in the DOM (`new Audio()`, Web Audio, media in a shadow DOM) is not seen by asking the renderer either, so a tab that began
to play sound in its current document is kept until it moves to another document. The renderer's answer (a media element
playing out loud) is read too, for a page whose sound signal did not come. The result is `discarded` (after the renderer
ended, in place of `pageCrashed`) or `discardRefused(reason:)`, with one line in host.log, `tab discarded tab=…` or `tab
discard refused tab=… reason=…`. A tab the host kept is looked at again after 30 minutes (Chrome's timer fires once per
hidden period, but a tab whose situation changed, such as a form sent since, may go later). The app takes a request the
host has not answered within 15 seconds as declined. **Look and setting:** in the panel's tab strip a discarded tab's icon is
smaller and fainter inside a dashed ring (Chrome's inactive tab look). Turning off Settings › General "Memory saver" (on by
default) reloads every discarded tab. The app side is `BrowserMemorySaver` (times and picking), `BrowserHostClient`
(sweeps, `wake`) and `BrowserTab` (what keeps a tab); the host side is `TabDiscarder`; the CEF side is the "Memory saver"
section of `YardletCEFBridge.c` |
| Passkeys (WebAuthn) | Chromium's own WebAuthn is used (windowless tabs too, in the Alloy style on top of Chrome's bootstrap). A windowless tab has no parent window, so Chrome's passkey dialog (Views `AuthenticatorRequestDialogView`) shows as a separate window of the host (`NativeWidgetMacNSWindow`). Which tab the window belongs to, where it shows and who closes it are set by "Chromium's windows and tabs" below (2026-10-27). What shows now: the phone and tablet passkey sheet (hybrid: QR code + Bluetooth) and the USB security key sheet (confirmed in QA from the dialog's text; registering end to end with a real phone or key has not been confirmed). Which sheet shows first when the site has no passkey anywhere is decided by Chromium 154's `AuthenticatorRequestDialogController`, with the same rules as Chrome (2026-10-25, checked against the source and with QA `--ui-fixture-browser-check-only=passkey`). (1) A conditional request shows no window, even when the person clicks the sign-in field (QA). (2) An immediate request (empty `allowCredentials`, "Sign in with a passkey") goes straight to the QR sheet without a list when the phone is the only choice ("single mechanism" in `IndexOfGetAssertionPriorityMechanism`). The Touch ID profile authenticator drops out of the list when it reports no credential for the site (`PopulateMechanisms`), and when Bluetooth is on, the USB security key becomes a button inside the QR sheet. Chrome adds iCloud Keychain as one more entry, and so shows a list first ("iCloud Keychain", "A different phone, tablet or security key"), only when it lacks permission to read iCloud passkeys. This host has no iCloud Keychain, so that difference remains. Changing it would mean changing that decision code (it is not in settings, feature flags or the CEF API), which was not done. What brings this Mac's own passkey (Touch ID) first instead (2026-10-27, from Chromium 154's `device/fido/mac/credential_store.mm`, `authenticator.mm` and `AuthenticatorRequestDialogController`): the Touch ID authenticator stays in the request only when it holds a credential for it. It looks up the keychain items of its access group whose label is the request's RP ID sealed with the profile's `webauthn.touchid.metadata_secret`. When the site lists the account's credentials (`allowCredentials`, as a site's passkey step after the email does), only listed IDs whose transports are empty or include `internal` count (Chromium reports `internal` for these passkeys when they are made); with an empty list, only discoverable ones count. A match with a list goes straight to Touch ID with no sheet (`HideDialogAndDispatchToPlatformAuthenticator`, when the site requires user verification or the Mac has a fingerprint reader; otherwise the account is shown first), a match with an empty list shows the account to confirm, and no match drops Touch ID, so a request for an account whose passkeys are on a phone, or one this Mac holds a passkey for on another site only, opens straight on the QR code (with Bluetooth on). Whether the person typed the email first matters only through which account's credentials the site then lists. Touch ID being available at all needs only the entitlement, a device owner check that the login password also passes (`LAPolicyDeviceOwnerAuthentication`, so a closed lid does not turn it off) and the Secure Enclave. Builds before 2026-10-24 lacked the matching group, and their host logged "Touch ID authenticator unavailable because keychain-access-group entitlement is missing or incorrect" for every request. All profiles share the default profile's metadata secret (see "Profiles" below), so a passkey made in one task's tab is found in every other. These passkeys carry Chromium's AAGUID `b5397666-4885-aa6b-cebf-e52262a439a2` (branded Chrome uses another), which a site's passkey list may name "Chromium Browser" (the passkeydeveloper AAGUID list), not "Chrome on Mac". QA `passkey` (2026-10-27, "a passkey on this Mac …") replays the decision with a CDP virtual authenticator on this device's transport standing in for Touch ID and Chromium's own dialog on (`enableUI`), its user verification standing in for the fingerprint: with the account's credential on this device the request was signed with no window; with the stand-in fingerprint refused it was not signed and the dialog said "Something went wrong"; with a listed credential this device does not hold, and with this device's credential being another RP ID's, nothing was signed and the dialog said "No passkeys" (both list only `internal`; when the list also names `hybrid`, as sites' lists do, the same decision leaves the phone and so the QR sheet, per the source and the "Sign in with a passkey" case above; the QA leaves that out so as not to touch Bluetooth). (3) For creation (no `authenticatorAttachment`), on a Mac with iCloud Drive on, Chromium puts iCloud Keychain first (`ShouldCreateInICloudKeychain`, `WebAuthenticationICloudKeychainForInactiveWithDrive` on by default, `IndexOfMakeCredentialPriorityMechanism`). This host has no iCloud Keychain, so it went straight to the next in line, the phone QR, and Touch ID was behind "Save another way". Since 2026-10-25, the host turns off Chrome's own setting `webauthn.create_in_icloud_keychain` whenever a request context is ready (`on_context_initialized` for the default profile, `on_request_context_initialized` for task profiles) (`set_windowless_preferences`, CEF `set_preference`). Then Touch ID (`Transport(kInternal)`) comes first, so the "Create a passkey in your Chrome profile" sheet (`kChromeProfileCreatePasskey`, "Continue" and "Save another way") shows first, and the QR appears only when chosen from "Save another way". In a build without Touch ID it is the QR, as before. It was confirmed that the value went into two QA profiles as `false`; that the Touch ID sheet shows first could not be confirmed, because that needs a signed build (based on the source). Chromium uses Bluetooth only if the Info.plist of the app that started the host (the responsible app = Yardlet) has `NSBluetoothAlwaysUsageDescription` (without it, "Cannot use Bluetooth because the responsible app … does not have Bluetooth metadata", and then only the security key sheet). So it is in both Yardlet.app and the host (`Packaging/Info.plist`, `Packaging/CEF/BrowserHost-Info.plist`, Korean in `ko.lproj/InfoPlist.strings`), and macOS asks for Bluetooth permission on first use. The dialog waits until the time the requesting site set, so the person must be able to see and close it. The host is normally not activated (`.prohibited`), so when a dialog appears (it also checks every second, because a window that appears behind another app's window gives no notice) the host switches to being able to activate (`.accessory`) and sends `chromiumWindow`. Yardlet places that window over the panel showing that tab (see "Chromium's windows and tabs" below), and when a newly placed window appears it follows the `ChromiumWindowPresentation` rules. If Yardlet is in front, it hands over activation (`activate(from:)`) so the window becomes key (security key PIN, Esc). If Yardlet is not in front (the agent pressed the button, or the person is in another app), it does so the next time Yardlet comes to the front, and after that it only raises the window without making it key. When no placed window is left, the host hands activation back to Yardlet (`ChromiumWindows`). The agent tools of the task that owns the tab add to their results that a dialog is open, with its title and tab number, and can close it with `browser_handle_dialog` (accept false) (`closeChromiumWindows(tabs:)`: sends Esc only to those tabs' windows and closes any still there after 0.5 seconds → the page gets `NotAllowedError`). When the page navigates, to another site or within the same site, the window closes as in Chrome (`WebContentsModalDialogManager::DidFinishNavigation`, the requesting document is gone; "closes when the page moves" in the 2026-10-27 QA `passkey`). For a request that wants only this device's passkeys (transports `internal` in `allowCredentials`, `hints: ["client-device"]`, `authenticatorAttachment: "platform"`), there is, as in Chrome, a "No passkeys: this device has no passkey for …" or "Your device can't be used on this site" sheet with only "Close". A conditional request (`mediation: "conditional"`) waits without a window (per the spec; (1) above). `passkeyPlatformAuthenticator` in `getClientCapabilities()` is true with hybrid alone (the spec: "locally and/or via hybrid transport"), so it is true without Touch ID. Touch ID (Chromium's profile passkeys) is on only in builds made with the prototype in section 7. The 2026-10-25 installed app was built that way, so the host's CEF constants and `keychain-access-groups` are `<team>.com.zzunkie.webauthn` and `…-uvk`, and the default profile has `webauthn.touchid.metadata_secret` (there is no `webauthn.touchid.last_used`, so it has not been used yet). What does not work is iCloud Keychain passkeys. Touch ID turns on only when the browser process's `keychain-access-groups` entitlement contains, letter for letter, the group fixed when CEF was built (`MAC_TEAM_IDENTIFIER_STRING "." MAC_BUNDLE_IDENTIFIER_STRING ".webauthn"` in `chrome_web_authentication_delegate.cc`, `containsObject` in `keychain_util.mm`), and the CEF distribution's group is `.org.chromium.Chromium.webauthn` with no team ID, which no profile can allow (hence the prototype in section 7). With `com.apple.developer.web-browser.public-key-credential` (Apple approval), iCloud Keychain goes through AuthenticationServices, but that discovery is created only when the web content has an NSWindow (`fido_discovery_factory.cc` `MaybeCreatePlatformDiscovery`). `GetNativeView()` of a CEF windowless tab is empty, so approval alone is not expected to turn it on (based on the source, not checked by running it). `isUserVerifyingPlatformAuthenticatorAvailable()` is true only in builds with Touch ID on |
| Vault | Facts the agent vault ([BROWSER_VAULT_DESIGN](BROWSER_VAULT_DESIGN.md)) confirmed in this host (2026-10-24, `run-check.sh … --ui-fixture-browser-check-only=vault`, a real CEF 154 QA bundle, test values only): (1) The CDP `WebAuthn` domain exists. With `WebAuthn.enable` and `addVirtualAuthenticator` (ctap2, `internal`, resident key, user verification, automatic presence), `navigator.credentials.create()` on `localhost` completes without a dialog (`authenticatorAttachment: platform`), `WebAuthn.credentialAdded` arrives, and `getCredentials` gives the private key. Putting that credential into a new authenticator with `addCredential` makes `get()` succeed, and `credentialAsserted` arrives. While the authenticator is attached, the tab's other authenticators (Touch ID profile passkeys, the phone) are not used, so the vault attaches it only briefly. (2) `Accessibility.getFullAXTree` gives a password field's value as one • per character (a 26-character test value → 26 •). (3) A value set in an isolated world (`Page.createIsolatedWorld`, name `yardlet-vault`) with the native `value` setter and `input` and `change` is accepted both by ordinary forms and by fields that hold their value React-style (that field's `input` event has `isTrusted: false`). `Page.addScriptToEvaluateOnNewDocument` and `Runtime.addBinding` (`executionContextName`) with the same name enter the same world, so the person's sign-in submission is received only through that world's binding (`Runtime.bindingCalled`). (4) Chromium's password manager does not store passwords (0 rows in `logins` of `Login Data`). The autofill history (`autofill` in `Web Data`) kept values of plain text fields: the user name, and the digits typed into one-character code fields without `autocomplete` (a code already expired). Fields with `autocomplete=one-time-code` and password fields were not kept. Since 2026-10-25, turning off address autofill (see "Autofill save offers" below) also keeps this history empty (QA: even after the vault step typed into an email field, `autofill` and `credit_cards` in all four QA profiles had 0 rows, and both settings in `Preferences` were `false`). (5) 2026-10-25: in a `Page.captureScreenshot` (PNG) image of an off-screen rendered tab, Vision `VNDetectBarcodesRequest` reads the page's two-step verification setup QR (`img`, 43 modules scaled pixel for pixel to 215 CSS px) and a Google Authenticator-style export QR (71 modules). |
| Profiles | Since 2026-10-24, one per task ([BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md)). When the `open` command has `profile` (`key`, `seedFrom`), the host opens the tab in a `CefRequestContext` whose `cache_path` is `Browser/Task-<key>` (tabs with the same key share one context, released when the last tab closes). Chromium opens only folders directly under the root cache as disk profiles and turns other paths into in-memory profiles ("Cannot create profile at path" in `chromium.log` and `host.log`). Disk profiles are read asynchronously, so a tab for a profile not yet read is created after `on_request_context_initialized` (`yardlet_cef_create_browser` returns 2 and reports with `YardletCEFEventProfileReady`). When a folder is newly created, the host puts in the default profile's Touch ID passkey key (`webauthn.touchid.metadata_secret`), opens the tab at about:blank, copies the starting cookies (from the `seedFrom` profile, or the default profile if there is none) through the cookie manager, and then opens the requested address. The copy puts cookies in the shape Chromium stored them: host-only cookies stay host-only, with the domain left empty, and partitioned cookies are left out because CEF does not take a partition key (before 2026-10-25, host-only cookies became domain cookies and `__Host-` cookies were dropped, so Google account sites sent the person back with `CookieMismatch`; [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 8). Navigation and DevTools messages that come while waiting for the profile or while copying are deferred until after. If the profile is not read within 20 seconds, the host gives up on the tab and reports it as a tab that could not open (2026-10-27; see "Number of tabs" above). The `copyCookies` command moves one site's cookies to another profile, and with `replace` first deletes the target's cookies of that site (the person's sign-in to the default profile and the tasks that follow the site; 2026-10-27, [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 11). When the `open` command's `profile` has `follow` (a list of sites), the tab takes those sites from the default profile in place of its own, and with `fill` the sites the profile has no cookie of, before the address opens (at about:blank, in order, like the starting cookies). The `cookieDigest` command answers a sum of hashes of one profile's cookies of one site (name, domain, path, value) with `cookieDigest`: whether a sign-in changed the cookies, without their values leaving the host. The `importCookies` command replaces the chosen sites' cookies in one profile with cookies the person imported from another browser: it first deletes that site's cookies, puts the new ones in through the same insertion path, and answers with `cookiesImported` (2026-10-26, [BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 10). Tabs without `profile` (the setting "Keep cookies: Shared by all tasks", tabs without a task) use the default profile `~/Library/Application Support/Yardlet/Browser/Default`. Session cookies are saved too (persist_session_cookies), so sign-ins survive a host restart (the same for task profiles) |
| Cookie encryption | When the host starts, it checks its own signature (`CookieKeychain`, Gatekeeper's Developer ID requirement). With Developer ID, it derives the key from the login keychain item "Chromium Safe Storage" (a random password), as Chromium does by default. That item trusts the signature of the host that created it, so updates signed with the same Developer ID do not ask. Ad-hoc and Apple Development builds, and `YARDLET_BROWSER_KEYCHAIN=mock` (QA runs), use the mock keychain as before (`--use-mock-keychain`, the fixed password `mock_password`). This is because an ad-hoc signature differs from build to build, so the login keychain permission window would appear every time; the price is that any program that can read this user account's files can decrypt the cookies. Which one is in use is recorded in the "cookie key in …" line at the top of host.log. The two keys differ. Cookie values are `v10` + AES-128-CBC (PBKDF2-SHA1 with 1003 iterations, salt `saltysalt`), and cookies that fail to decrypt are not read (`sqlite_persistent_cookie_store.cc` `kDecryptFailed`). So switching from mock to Developer ID (or back) signs the built-in browser out of every site once. There is no code to migrate existing cookies (it would have to rewrite the user's profile database) |
| Autofill save offers | 2026-10-25. When a form containing a card or an address is submitted, Chromium's autofill shows a Chrome bubble offering to save it, and that code (`SaveCardBubbleControllerImpl::DoShowBubble`, `AddressBubblesController`) fetches the tab's Chrome window without checking. A windowless tab has no such window, so the browser process read a null pointer (SIGSEGV, address 0x10) and the host ended along with every tab. This also ended the host on a real Stripe Checkout payment page. In the same place as the passkey setting (`set_windowless_preferences`, whenever a request context is ready), the host turns off Chrome's own settings "Save and fill payment methods" (`autofill.credit_card_enabled`) and "Save and fill addresses" (`autofill.profile_enabled`). Then autofill does not extract cards, addresses or IBANs from submitted forms (`FormDataImporter::ExtractFormData`) and offers nothing. With the address setting off, form history (autocomplete, `autofill` in `Web Data`) is not kept either. Autofill's suggestion list appears only when the tab's view is inside a window (`CanShowRootPopup`), so it does not appear in a windowless tab (based on the source) |
| Locale | If Yardlet's first language is Korean (the system's, unless Settings › General › Language chooses one), the Chromium UI locale is `ko` and Accept-Language is `ko-KR,ko,en-US,en`; otherwise `en-US` |
| URL policy | Only http, https, file, about and data open. Typed addresses, page links, redirects, script navigation and form POSTs (including 3-D Secure, which goes to another site and back), new windows and the agent's CDP `Page.navigate` are all filtered against the same list in the host's `on_before_browse` (the first address of a new window in `on_before_popup`). A blocked address shows a notice in the panel. Since the evening of 2026-10-25, other apps' addresses (`mailto:`, `tel:`, `zoommtg:`, `slack:` …) go to "External app addresses" below instead of a notice. Chromium's own addresses (`blob`, `chrome`, `chrome-extension`, `devtools`, `view-source`, `ws` …), addresses Chrome does not hand to other apps (`kDeniedSchemes` in `external_protocol_handler.cc`: `javascript`, `data`, `file`, `shell` …) and single-letter schemes (Windows drives) are blocked with a notice as before (`is_external_scheme`). The address field and the agent's `browser_navigate` still open only the five. Since 2026-10-26 the address field opens input that is not an address as a Google search (the default search engine of Chrome's address bar, `BrowserURLPolicy.addressFieldURL`) |
| Address suggestions | 2026-10-27. While the person types in the panel's address field, a list under it suggests pages and searches as Chrome's omnibox does (`BrowserAddressAutocomplete`, `BrowserAddressRanking`); the list runs from the field's start to the panel's edge, so a narrow panel still shows titles and addresses. The rows are what was typed (the address, or a Google search shown as "‹text› – Google Search"), pages from the history, past searches and Google's suggested searches: at most 8 (10 when no page is among them), the first row first, then searches before pages, as `AutocompleteResult::SortAndCull` orders them. The scores are Chromium's. A page typed before completes the text inline, selected after the caret (a host typed once, another page typed twice, `HistoryURLProvider::CanPromoteMatchForInlineAutocomplete`; relevance 1413, above what-you-typed's 1203 and a verbatim search's 1300). Other pages must match every typed word at a word start of the address or title (in the host also inside a word) and score by where they match and by how often and how recently they were visited (`ScoredHistoryMatch`: the last 10 visits, a typed one worth 1.5, recency from 1 down to 0.1 over a year, buckets 550–1399); a page counts once it was typed, visited four times or seen in the last 3 days. Past searches that start with the text come from the history's results pages (`SearchProvider::CalculateRelevanceForHistory`). There is no completion right after deleting, with the caret before the end, or while an input method composes. Keys as in Chrome: ↑ ↓ and Tab ⇧Tab move through the rows, wrapping around, and put the row's text in the field; Return opens the selected row; Escape first goes back to the first row, then closes the list, then shows the page's address again all selected, then gives the page the keyboard; ⇧fn⌫ (Shift-Delete) and a row's × remove a page or past search from the history. A click opens a row. **History:** one for every task's tabs (`BrowserAddressHistory`, `Browser/AddressHistory.json`), as Chrome keeps one per profile: task profiles keep sign-ins apart, and the pages are the person's. Each page a tab commits is a visit (`BrowserHostClient.noteHistory`), typed when the person opened it from the address field; the same address again (a reload, a move within the page, a restored or woken tab) and an error page are not. User names and passwords in an address are dropped, a Google results page counts as its search, and visits older than 90 days (Chrome's `kExpireDaysThreshold`) and pages past 5000 are dropped. Chromium's own `History` in each profile is not used: CEF opens every address as typed, the agent's and restored tabs' too (300 of 633 pages in one profile), and its C API neither reads nor deletes from it. The agent tools do not read this history. **Search suggestions:** Settings › General "Autocomplete searches and URLs" (Chrome's `search.suggest_enabled`, on by default as in Chrome). While it is on, what is typed goes to `https://www.google.com/complete/search?client=chrome&ie=UTF-8&oe=UTF-8&hl=…&q=…` at most once every 100 ms (`kDefaultMinimumTimeBetweenSuggestQueriesMs`), from Yardlet rather than the page's profile, with no cookies and no cache, so the suggestions are not personalized as a signed-in Chrome's are. An address that may be private is not sent: a path, a scheme other than http(s), a user name, a port, a query or fragment, or an https address's path (`IsQueryPotentiallyPrivate`). Off, nothing is sent and history suggestions stay, as in Chrome. Turning the setting off leaves only its value; removing the feature leaves `AddressHistory.json` in Yardlet's browser folder |
| External app addresses | Evening of 2026-10-25. Follows Chrome 154's rules (`ExternalProtocolHandler`). The host cancels such a navigation and sends `externalApp(tab:request:)` (the address, the origin of the requesting document, the user gesture, and whether that origin has "always allow"), and Yardlet decides (`BrowserHostClient.handleExternalApp`, `BrowserExternalAppPolicy`). (1) Once a page has made a request, further requests from it do nothing until the next click or key press (by the person or the agent) (Chrome's flood protection `g_accept_requests`). (2) If no app opens the address, or that app is Yardlet itself, nothing happens (Chrome only logs it to the console). (3) `mailto:` opens in the default mail app without asking (Chrome: "every platform provides a default handler for it"). Origins and address kinds the person set to "always allow" do not ask either. (4) Otherwise, when the panel shows that tab, a bar over the page asks: "Open ‹app›?", "‹origin› wants to open this application.", Cancel and "Open ‹app›" (Chrome's wording; the app name comes from LaunchServices `urlForApplication(toOpen:)`). If the origin is secure (https, loopback http on this Mac; Chrome `MayRememberAllowDecisionsForThisOrigin`), there is an "Always allow ‹site› to open links of this type in the associated app" box, and when the person checks it, the host writes Chrome's own setting `protocol_handler.allowed_origin_protocol_pairs` (`{origin: {scheme: true}}`) to the tab's profile (`allowExternalApp`). (5) A request that came from the agent's input asks even in case (3): if the tab's last input was an agent tool call (`BrowserTab.isDrivenByAgent`; the person's input is a click or key press on the page in the panel, or the address, back, forward or reload), only the person opens it, from the bar. The agent tools add that fact to their result. An app address opened as a new window (a `target=_blank` mail link) does not create a tab (Chrome closes that tab). The bar goes away when the page changes to a new document (like Chrome's tab-modal windows). Yardlet does the opening with `NSWorkspace.open`; QA runs (`YARDLET_QA_BACKGROUND`) do not open anything. host.log has `external app tab=… scheme=… remembered=…` (the address is not logged). The two apps (bundle bytes): the Claude app 3.1623.3's Browser pane blocks anything other than http and https without asking (`block-silent`), and the Codex app 26.1016 blocks anything other than http and https in tabs the agent uses (`Browser Use URL policy`). For other navigation, the Owl framework has setting names matching Chrome's question wording, but whether they are used is not known |
| Default browser | 2026-10-27. Yardlet can be chosen as the Mac's default web browser (System Settings > Desktop & Dock > Default web browser). Yardlet never asks to be chosen, and nothing changes until the person chooses it. **What macOS needs:** Launch Services counts an app as a web browser (`LSApplicationRecord.isWebBrowser`, which that setting lists) only when it claims both `http` and `https` (`CFBundleURLTypes`) and views `public.html` (`CFBundleDocumentTypes`). In a check with test bundles registered and unregistered again, http and https alone, https with HTML, and HTML alone were not browsers; http, https and `public.html` was, with `LSHandlerRank` `Alternate` too. Apple's criteria for the passkey entitlement (`com.apple.developer.web-browser.public-key-credential`) name only the two schemes in `Info.plist`. `Packaging/Info.plist` claims http and https and views HTML and XHTML as an `Alternate` handler, so Yardlet does not become the default for HTML files by itself. Only Yardlet.app claims them; the browser host and the helpers do not, so they never show as browsers. **Where a link opens:** the app delegate takes `application(_:open:)`, and the main window's content has `handlesExternalEvents(preferring: ["*"], allowing: ["*"])` so that an open window takes the link. Without it SwiftUI also opened a new window for each link (QA, 1 window to 3 after two links); with the scene's `handlesExternalEvents(matching: [])` instead, a link or file that launched Yardlet got no window at all, so nothing opened (a cold launch of the QA bundle, 0 windows). `AppModel.openExternalLinks` opens each link or HTML file in a new tab of the side panel of the task the window shows (its focused pane in a split view), shown, with the panel open, as a link in the conversation opens; on the new-task screen, in that screen's panel, whose tabs the task it starts takes over. The window keeps showing the task. A task with no room for another tab (9), or an empty split pane, which has no side panel, sends the link to the new-task screen in the window's tab for it, as ⌘T opens it; with no room there either, to another browser. Links that come while launch reads the task index wait for it. Bringing Yardlet in front is Launch Services' part, which does it unless the opening app asked otherwise; Yardlet only takes a minimized main window out of the Dock or opens a closed one again, as Chrome shows the window it opens a link in, and leaves a window already showing as it is. Chrome opens an outside link in a new tab of the window used last, and Arc, by default, in a small window of its own (Little Arc); Yardlet follows Chrome, in the place its conversation links already open, so the page shows beside the task without taking the window. A tab opened there is that task's tab, which its agent can use too, as with any tab the person opens. **Never back to Yardlet:** "Open in External Browser", the conversation link menu's "Open in default browser" and the last step above go through `OutsideBrowser`: the Mac's default browser, or Safari when that is Yardlet (any copy with Yardlet's identifier, since a development build shares it), so the address does not come back. A task's own fallback when it has no room (a conversation link, a task's server) still asks the default browser; when that is Yardlet, the link takes the steps above. QA: `--ui-fixture-browser-check-only=external-links` (section 11) |
| Downloads | Saved without asking to the user's `~/Downloads` under the suggested name; if the name is taken, `name (1).ext`. The host has `LSFileQuarantineEnabled`, so downloaded files get the quarantine attribute. If the panel is open, when a download finishes the Dock's Downloads stack bounces, a notification appears if notifications are allowed, and "Show in Finder" appears at the bottom of the panel (without a panel the file is only saved). From the second automatic download on the same page (several files from one click, file saves a script made), Yardlet asks for the "Download multiple files" permission as Chrome does (see "Permission requests" below). Before 2026-10-25 no one answered, so those downloads silently disappeared (QA). When a tab a page opened as a new window (a file address opened with `target=_blank`) ends in a download without ever showing a page, Yardlet closes that empty tab and brings the opening tab to the front, as Chrome does (`.download` in `BrowserHostClient`; the opening tab is known from `openedTab`). It closes the tab after the download finishes. CEF stops reporting a download whose tab has closed, so closing early would leave the panel's download line without an end |
| JS dialogs | Since 2026-10-27, alert/confirm/prompt/beforeunload belong to their tab, as Chrome's tab-modal dialogs do. The tab holds the dialog (`BrowserTab.javaScriptDialog`, until it is answered, its page goes or its renderer ends), and the panel that shows the tab draws it over the page (`BrowserJavaScriptDialogView`). The title includes the host name of the requesting page, so a page cannot pose as Yardlet. Only that page is blocked: the conversation, the sidebar and the other tasks stay usable. When the panel goes to another tab or task the dialog hides, and it shows again when the panel shows the tab; it is never cancelled and has no time limit (Chrome's alert also waits until it is answered). The dialog takes the keyboard only when the page had it as the dialog came (Return accepts, Escape cancels), so a dialog the agent's click opened does not take what the person is typing in the composer. Whoever answers first, the panel or the agent (`browser_handle_dialog`), the other learns of it through the client-made `dialogClosed` event. Before, the dialog was a sheet on the panel's window, which blocked the whole window (including the sidebar to other tasks), it was cancelled when the panel was not in a window or went to another tab, and a dialog of a tab no panel showed never appeared when the tab was shown later. If the panel is closed, Yardlet does not answer (section 6). Since the evening of 2026-10-25, when the person closes a tab in the panel (✕, ⌘W, the close items in the tab menu), the page is asked first, as in Chrome: a tab open in the engine is closed with `requestClose` (host `close_browser(0)`), and for a page that uses "confirm before leaving", the tab stays in the panel while that question comes and is asked with Chrome's "Leave site?" (Leave and Cancel, the same sheet as the navigation question). With Cancel the tab and page stay; with Leave, once the host has closed it (`closed`), the panel goes to the tab used before it, as with other tabs. CEF closes pages without such a handler at once (`NeedToFireBeforeUnloadOrUnloadEvents`). If a tab that is not visible asks, Yardlet brings it to the front to ask (as Chrome activates that tab to ask, `BrowserTab.closeQuestion`). If within 1 second the page neither asks nor closes (`BrowserHostClient.closeAnswerWait`), the tab is closed at once as before: Chromium gives a renderer that does not answer 500 ms and then closes, but does not apply that timeout to a tab with DevTools attached (`WebContentsImpl::ShouldIgnoreUnresponsiveRenderer`). Each close waits its own second (`BrowserTab.closeRequests`): after the person stays (Cancel) and closes again, the new close is asked again. Before the evening of 2026-10-27, the first close's wait could end the second close within its first second without asking. The agent closing a tab, archiving or deleting a task, and quitting the app do not ask. For a tab Yardlet closes at once like this, the host answers its beforeunload with "Leave" right away (`BrowserSlot.closing`), and a question that has already reached Yardlet is answered with Leave too (`leaveDialog`). CEF asks the page first even on a forced close (`close_browser(1)`) (`DispatchBeforeUnload` in `AlloyBrowserHostImpl::CloseBrowser`), but that tab had already left the panel and the client, so there was nowhere to answer. So before 2026-10-25, closing the tab of a page that uses "confirm before leaving" (editors, mail composition) left its browser and renderer behind, invisible, until the host ended (QA: the closed tab's `javaScriptDialog` kind 3 was cancelled at shutdown with "requires a parent window handle"). Now it closes within 1 second (host.log `browser closed tab=…`) |
| File choosers | Since 2026-10-27 the chooser waits in its tab (`BrowserTab.fileDialog`) until the panel or the agent (`browser_file_upload`) answers it, the page moves to another document (the request was that document's, so the host gets a cancel), its renderer ends or the tab closes. There is no time limit (Chrome's chooser also waits until the person answers). For a tab Yardlet closes, the chooser is cancelled first so the host lets go of its callback (before, it kept one of the host's 32 pending slots after the tab was gone). A chooser the person's input opened (a click or key in the panel) opens as the system's `NSOpenPanel`/`NSSavePanel` while the panel shows the tab: not a sheet but a child window of the panel's window, which moves with the window without blocking it, placed at the top center of the page (`BrowserFileChooserPanel`). When the tab stops showing, it closes unanswered; when the tab shows again, it opens again. A chooser the agent's input opened does not open the system's window: it waits in a bar over the page ("The page asks for a file", Cancel and Choose File…), for the agent to answer or the person to open. The system's window takes the keyboard as soon as it opens, so the agent's click would take what the person was typing. Before, the chooser was a sheet on the panel's window, which blocked the whole window (no way to another task), and it was cancelled at once when the panel was not in a window. The page's `accept` extensions are passed as the allowed types. `multiple`, `webkitdirectory`, `showOpenFilePicker` and `showSaveFilePicker` arrive in their own modes (QA `compat`). `showDirectoryPicker` arrives as opening a file (section 10) |
| Permission requests | 2026-10-25. When a page requests something Chrome asks about with a permission bubble (notifications, location, clipboard read, downloading multiple files, cookies of other sites, local network, fonts, window management and so on), CEF calls `on_show_permission_prompt`. In the Alloy style without a handler, CEF does not answer (`CEF_PERMISSION_RESULT_IGNORE`), and the page's request never finished (QA: `Notification.requestPermission()` never finished, location finished only on the timeout the page set, and the second download on the same page disappeared). Now the host passes it on as `permissionPrompt` (the site and Chromium's permission names), and when the panel shows that tab, a bar over the page asks ("‹site› wants to: Show notifications", Block, Allow and Close). The answer goes back as `permissionResult` (allow, block or dismiss), and Chromium remembers allow and block per site (as Chrome does; it does not ask on the next visit). When the page goes elsewhere or the tab closes, CEF calls `on_dismiss_permission_prompt` and the bar goes away. While the panel is not showing that tab, the request waits (Chrome also asks when that tab comes to the front), and the agent tools add that fact to their result (only the person answers). Since the evening of 2026-10-25, camera and microphone (`getUserMedia`) ask through this bar too ("Use your camera", "Use your microphone"). CEF's `on_request_media_access_permission` denies at once by default in the Alloy style, so the host asks Yardlet with its own prompt number (2^62 or higher) and records the answer in Chrome's own site settings (`CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA` and `_MIC`, in that tab's profile) so it does not ask next time (block denies at once, allow allows at once). When allowed, Chromium opens the device, and at that point macOS asks once, the first time, about Yardlet's access to the camera and microphone (the usage descriptions in the app's Info.plist; the host has the same keys and entitlements). Chromium does not ask macOS before the site is allowed (content `MediaStreamManager`, CEF `media_access_query.cc` source). When the page changes to a new document, the tab closes or the renderer ends, the request is released and ends as denied. Screen sharing (`getDisplayMedia`) is denied as before, because Chrome's screen and window picker does not exist for a windowless tab. The Codex app 26.1016 asks about the same requests with an allow, allow this time and deny window (`setPermissionPromptHandler`), and the Claude app 3.1623.3 denies everything except clipboard write (both from bundle bytes) |
| PDF | 2026-10-25. Chromium's PDF viewer (`index.html` of the built-in extension `mhjfbmdgcfjbbpaeojofohoefgiehjai`) opens in a frame inside the PDF page, and the tab title becomes the file name. The URL policy used to block that frame's `chrome-extension:` address, so every PDF was a blank screen (panel notice "Blocked chrome-extension://mhjf…/index.html"); now only subframes going to that extension pass (`is_pdf_viewer_frame`). A tab or the address field going to that address is still blocked. The viewer's download button leads to a download, and its print button to "Printing" below |
| Certificate errors | Chromium shows its own warning page in the tab ("Privacy error", Advanced → Proceed to ‹host› (unsafe)). Since 2026-10-25 the panel does not lay its error card over certificate errors (`net::IsCertificateError`: -200 to -219, and -150). Before, the card ("Page unavailable ERR_CERT_AUTHORITY_INVALID", Try again) hid the warning page and its buttons. QA confirmed that with a self-signed certificate, Advanced → Proceed opens the page (`compat`). For errors Chromium does not let the user skip (HSTS sites and so on), the warning page has no such button |
| HTTP authentication | Chromium's own sign-in window (Views `LoginView`: user name, password, Cancel and Sign in) shows as a separate window of the host, like the passkey dialog (confirmed in 2026-10-25 QA from the window's text, without actually signing in). As in Chrome it is a web-modal dialog of the tab (`LoginHandler`), so it follows the `ChromiumWindows` rules unchanged (the tab's window, over the panel showing that tab, handing over activation, closing by that task's agent; see "Chromium's windows and tabs" below). When the window appears, the tab's document has already changed to Chromium's empty error page (`chrome-error://chromewebdata/`) (snapshot in 2026-10-27 QA). Since the evening of 2026-10-25 the host reports a kind for each window (`kinds` in `chromiumWindow`: among Views windows, signIn if the title is Chromium's own "Sign in" or the Korean for "Sign in" (`IDS_LOGIN_DIALOG_TITLE`, in the host's two locales), passkey for other Views windows, print for AppKit modal windows). The agent tools call this window "Chromium's sign-in window for the site's HTTP authentication" and say that closing it cancels the sign-in. Before, they called it "Chromium's passkey dialog" (reproduced in QA) |
| Printing | `window.print()` and printing from the PDF viewer take the path where Chromium opens the macOS print window (`NSPrintPanel runModalWithPrintInfo:` in `PrintingContextMac::AskUserForSettings`) as a separate window of the host. CEF does not use print preview for windowless tabs (`CefBrowserPlatformDelegate::IsPrintPreviewSupported`). This is based on the source; it was not run in QA because a system window would appear. The Codex app calls `webContents.print()` (the same system window) from its print command. Since the evening of 2026-10-25 the agent tools call this window "the system's print dialog" (the host reports AppKit modal windows as print; based on the source, not seen in QA). This window is not a dialog of the tab but an app-modal window without a parent, so it does not hide with the tab, and which tab it belongs to cannot be known. So no task's agent can close it, and the tools mention it only when they fail, with "which tab opened it is not known, so it may be another task's". Yardlet leaves this window where it is and raises it just above Yardlet's frontmost window. Whether the print window blocks input to other tabs was not checked in QA (in the source it is a modal loop running in a `CATransaction` completion block, and the host's input comes as Yardlet's commands rather than window events, so it is not expected to block it) |
| Chromium's windows and tabs | 2026-10-27. A passkey window opened by one task or by the person was added to the agent results of every task as "is open over the browser", and any agent could close it with `browser_handle_dialog`. An agent reported a passkey window open on the Stripe tab, but when the person opened that tab there was no window, and clicking a Yardlet window sent the window to the back with no way to bring it back. **Which tab a window belongs to:** the passkey dialog and the sign-in window are web-modal dialogs of their tab, as in Chrome. But in a windowless tab on macOS the parent is empty (CEF 154's `AlloyWebContentsDialogHelper::GetHostView` is empty for a windowless tab, the Aura-only `GetAcceleratedWidget` is `NOTIMPLEMENTED` on Mac, and `parent_view` is not used even when given), and there is no CEF callback that names the tab when the window appears (the dialog's size comes from the stored `GetContainerBounds`). The link that remains is Chromium's rule: when the tab is hidden, the dialog hides within the same call, and when the tab is shown, it appears again (`WebContentsModalDialogManager::OnVisibilityChanged`; CEF `WasHidden` calls `WebContents::WasHidden` directly on the host's main thread, which is the UI thread). So for each `visibility` command from Yardlet, the host (`ChromiumWindows`) compares the windows before and after and records the windows that disappeared or appeared in between as that tab's. When a new window appears while there are tabs that are not hidden, it belongs to that tab if there is only one; if there are several, the host hides each tab for one call and shows it again at once, and assigns the window to the tab whose hiding makes it disappear (those pages see `visibilitychange` twice, very briefly). If it still cannot tell, the tab is -1. The print window has no tab (see "Printing" above). `chromiumWindow` carries `ids` (window numbers) and `tabs` (the tab, -1 if unknown) for each window. In QA ("Chromium's windows belong to their tab" in `compat`), with tabs [1, 3] not hidden it correctly found the window of tab 3 of another task, and with [1, 3, 4, 5] the window of tab 5. **Who hears about it and closes it:** the agent tools add only the windows of their own task's tabs to results (the tab number, "Chromium ignores input to that tab until it closes", that the person sees it only when that task's panel shows that tab, and that `browser_handoff` shows that tab to the person), and close only those windows (`closeChromiumWindows(tabs:)`). Other tasks' windows appear neither in results nor in closing. A window whose tab is unknown cannot be closed by any agent. While such a window is open, Chromium drops input to that tab (the person's clicks do not reach the page, QA). So the agent's click, typing, key and scroll tools send nothing to that tab and answer with a failure: "The click was not sent to tab 3." followed by the window's name and kind, that it closes with `browser_handle_dialog` (accept false), and that `browser_handoff` shows that tab to the person. Before the evening of 2026-10-27 they answered "Clicked" although the click was dropped (QA). Reading tools (snapshot, screenshot, evaluate) and navigation work as before. Other tabs and other tasks' tabs take clicks, typing and navigation, and the person's panel takes clicks too (QA). **Where it shows:** Chrome draws a tab's dialog over that tab. Yardlet (`ChromiumWindowPresenter`) finds, for each window, the on-screen panel showing that tab and gives the window a place with `presentChromiumWindows`: centered at the top edge of that panel's page (within that screen), and just above that panel's window (`order(.above, relativeTo:)`, which works with another process's window number too, QA). A window whose tab is unknown stays where it is and is raised just above Yardlet's frontmost window. A window not placed (no panel shows its tab: the agent's background tab, or the person is in another task) waits off screen, transparent, and appears over the panel when the panel shows that tab. When a window appears over a tab of a task whose panel is not on screen, Yardlet opens that task's side panel at that tab, as `browser_handoff` does. It does not change the task the person is looking at, and if that task's panel is showing another tab on screen, it leaves it as it is. Since the evening of 2026-10-27 this takes the same path as every other wait: a mark on the panel tab, "Waiting in the browser" on the task's row and one notification ("Tabs that wait on the person" below, `AppModel.refreshBrowserWaits`). Before, `onChromiumWindowOverHiddenTab` only left the panel on the tab and sent no notification. Windows are placed again when the windows change, when a panel starts or stops showing a tab, when a panel comes on or goes off screen, when Yardlet comes to the front, when a Yardlet window becomes key or main, moves or is resized, and when a Yardlet window is clicked (an `NSEvent` local monitor, after AppKit has brought that window forward). Each time, the window is raised just above that panel's window, so even after a click on a Yardlet window it comes back to the front. The always-on-top level (floating) is not used, so when the person goes to another app, that app's windows come on top. The host's one-second timer does not raise windows (if it did, they would come back over other apps). QA does not actually click a Yardlet window (that would take the person's screen); it sends that window to the front and then calls the click-handling path (`yardletWasClicked`), and checks in the window server's front-to-back order (`CGWindowListCopyWindowInfo`) that the Yardlet window came to the front and then the sign-in window came in front again |
| Tabs that wait on the person | 2026-10-27. The request: a window such as a passkey QR code or a file attachment should wait in the background and show when the person opens that task's browser, or take the person to the task that opened it. What a tab waits on from the person is one value, `BrowserHostClient.personWait(of:)`, the most pressing first: the agent's handoff still waiting for an answer (`browser_handoff`) > one of Chromium's windows over the tab (passkey, sign-in) > a permission request > another app to open > a JS dialog > a file chooser. The tab holds every one of these windows and bars, and they show over a panel only while that panel shows the tab (each row above). While a tab waits: (1) the tab in the panel's tab strip gets an orange dot (only a tab not shown; its help and accessibility name say what it waits for, such as "‹site› asks for a passkey"); (2) the task's sidebar row ends with an orange globe, "Waiting in the browser" (`SidebarTaskStatus.waitingInBrowser`, ranked after a question). It is `TaskAttentionDetail.browserWait`, so the Dock badge, ⌥⌘A, the activity list and the menu bar count it too; (3) one macOS notification goes out ("Waiting for you in the browser", body "‹task title›: ‹site› …"). No notification is sent when the tab shows in a panel on screen and Yardlet is in front, nor for a handoff, which has its own; it is withdrawn when the wait ends. Clicking it opens the task with its panel on that tab (`SystemNotificationTarget.browserTab`). For a task whose panel is not on screen, the panel is left on that tab when the wait begins, so the person finds the window when they go to the task. Yardlet never moves the person's screen to that task: changing the screen while the person types or reads in another task is exactly taking the screen, and the Codex app likewise holds a browser show request for the conversation it belongs to and goes to that conversation and tab only when the person clicks a web notification (bundle bytes, `open-handler`, `onWebNotificationClicked`). A JS dialog or file chooser that the agent's input opened can be answered by the agent, so it does not count as a wait while that task's turn runs (`BrowserPersonWait.agentLed`; the panel tab is still marked). If it is still open when the turn ends, it waits like the others from then on. The agent's results still report only their own task's tabs |
| The tab the person uses | 2026-10-27. The request: when the person is using one of several tabs, the agent should use another tab without taking the screen. `BrowserHostClient.personUse(of:)` says whether the person is using a tab: a panel on screen shows it, and its page has the person's keyboard (the panel's view is the first responder of the key window, `setPanelKeyboard`) or the person's last click, key, scroll, drag, input-method text, address, Back, Forward or Reload came within 30 seconds (`personUseWindow`). 30 seconds covers a pause while reading before the next scroll. The Claude app's 5 seconds (`isCompetingUserIntent`, `lastUserInputAt`) decides whose input a pop-up or navigation came from, which is too short for this. Meanwhile the agent's `browser_tab_select` and `browser_tab_new(foreground)`, and a new window that the agent's tab opens in front, do not change the tab the panel shows. That tab becomes the agent's active tab (`agentFronts`, `agentTab(forSession:)`), which tools without a `tabId` use. When the person shows another tab in the panel, an agent that worked in the front tab during its turn keeps that tab as its active tab, so its calls without a `tabId` do not move to the tab the person just showed. When the panel shows the agent's tab, the two are one again; when the turn ends (`endAgentTurn`), the agent's active tab goes, and the next turn's first call without a `tabId` uses the panel's tab again. The panel's tab strip puts a sparkles mark ("The agent is using this tab") on the tab the agent used last in its turn (`agentUsedTab`) when that tab is not the one shown. When the agent uses a tool on the tab the person is using, nothing is refused: the result ends with that fact and with `browser_tab_new` and `browser_handoff` ([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) section 2, "The tab the person uses"). When the person is not using the panel, it follows the agent as before. The two apps (bundle bytes): in the Claude app 3.6556.2, `tabs_select` changes the active tab the person sees, and omitting `tabId` uses that tab (no protection by input). The Codex app 26.1021 keeps the tab the agent chose (`selectedTabIdsByRouteKey`) apart from the active tab on screen, opens tabs the agent creates inactive and defers showing them until the panel is visible, and draws a blue cursor overlay on the tab the agent uses |
| Payment API (wallet buttons) | Evening of 2026-10-25. The browser process starts with `--disable-features=WebPayments` (in the same place as `NativeNotifications`, which turns off notifications, `disable_features`). Chromium sets `WebPreferences.payment_request_enabled` from that feature (`WebContentsImpl`), and Blink turns `PaymentRequest` on from that value, so pages have no `PaymentRequest`. Then payment pages that choose wallet buttons such as Google Pay and Apple Pay through that API do not show the buttons, and the person pays by entering a card. Before, the buttons showed, but `show()` always ended with `AbortError` because there was no Chrome window. The two apps (bundle bytes): neither the Claude app nor the Codex app has anything in its app code that turns this API off, and their frameworks have Blink `PaymentRequest` implementation strings. The earlier conclusion that the Claude app's Electron lacks this API was not confirmed in the bytes |

## 4. Input

- Mouse (click, drag, move, exit), wheel and trackpad (precise deltas and momentum phases carry straight through to page
  scrolling), pinch zoom.
- The mouse's back and forward buttons (buttons 4 and 5) go back and forward in the tab's history when released over the
  page, as the Codex app's browser page sends them, and do not reach the page: Chromium's off-screen mouse input knows
  only left, middle and right. Over the page they are the page's, so the window's Back and Forward do not run; anywhere
  else in the window they are the window's (`MouseNavigationMonitor`, `MouseHistoryNavigating`).
- Keys: a full table from macOS virtual key codes to Windows key codes (`BrowserKeyCodes`, based on Chromium's
  `keyboard_code_conversion_mac.mm`): letters, digits and symbols, arrow keys, Home/End/PageUp/PageDown, Delete, F1 to
  F20, keypad, modifier keys (Shift/Control/Option/Command/ Caps Lock, left and right told apart), the Korean/English
  key (`kVK_JIS_Kana` → VKEY_HANGUL). Modifier keys send press and release through flagsChanged.
- Input methods such as Korean: the panel view is an `NSTextInputClient`. Text being composed goes as `composition.set`
  (with underlines), committed text as `commit`, and the end of composition as `finish`; keys the input method used show
  in the DOM as `Process` (229). When the input method commits text and passes the key on (`doCommandBySelector:`,
  Return, arrow keys or Tab after Korean composition), the key itself is sent after the committed text (2026-10-24, as
  in Chrome's `render_widget_host_view_cocoa.mm`; before, the first Return after composition did not reach the page).
  The candidate window's position uses the character bounds the host reports.
- Password fields (2026-10-25): while a password field on the page (`<input type=password>`, in any frame) has the
  keyboard, that is, while the focused field of the visible tab is a password field and the panel view is first
  responder of the key window, Yardlet turns on secure input (`EnableSecureEventInput`) as Safari does and allows only
  Roman input sources in the panel view's input context
  (`allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`, WebKit
  `WebViewImpl::updateSecureInputState`). Entering a password field with a Korean input source switches the input source
  to a Roman one, and other processes cannot snoop on the keys. Before, the input method's Korean composition went in as
  is (hidden behind dots, so it could not be seen). Both are turned off on another field, when the panel loses the
  keyboard, on another tab, when the panel closes (the view leaves the window), on another window, sheet or app (the
  window's key state), on renderer exit and on host exit (the tab detaches from the view), and they are turned off as
  many times as they were turned on (`BrowserHostView.updateSecureInput`, `BrowserSecureInput`). AppKit takes first
  responder away from a hidden view, so they turn off with it. The input source limit applies only to that view's input
  context, so it does not linger in the conversation composer or other apps, and the system withdraws secure input when
  the process ends. Chrome does the same with `ui::ScopedPasswordInputEnabler` (secure input, and only ASCII input
  sources through `TSMSetDocumentProperty`) and also turns off the input method in password fields by returning nil for
  `inputContext`. Yardlet does not turn off the input method (section 10). The renderer reports the field's kind. CEF
  154's windowless view does not give the browser process the kind of the focused field (`on_virtual_keyboard_requested`
  gives only `inputmode`, and only when the input method is brought up). So the Helper's renderer handler
  (`YardletCEFHelper/FocusedField.c`) sends a process message whenever a frame's focus changes
  (`on_focused_node_changed`, the standard CEF path cefclient uses for editable-field notices), saying whether the newly
  focused element is a password field, and the host emits a `passwordField` event for each tab only when the value
  changes. When a new document comes into the main frame (or the frame that had the password field), the host turns the
  state off and asks that renderer for the field focused now. This is because a page restored from the back-forward
  cache comes back with focus in a field and reports no focus change. Reports from frames a new document replaced
  (`is_valid` false) are dropped, and the state turns off when the renderer ends. The tab holds the last value and uses
  it when the panel shows it again.
- Keyboard focus: when the panel view is the window's first responder, the visible tab's page has focus (`focus`). When
  the same view shows another tab (between browser tabs, a reopened tab, a replaced tab), the tab that was shown loses
  focus and the new tab gets it (2026-10-24, as in Chrome. Before, focus was sent only when the view became first
  responder. In QA, even then, clicking the page made Chromium give focus, so the caret and input were right).
- Focus stays when the page changes (2026-10-24): navigation to a new document (links, form submission, script
  navigation, back and forward, reload, back-forward cache) and the commit of a cross-site iframe. Chromium hands focus
  to the renderer of a new page view or iframe only if the previous view had focus (`old_view->HasFocus()` in
  `RenderFrameHostManager::CommitPending`), but in CEF 154's windowless view `HasFocus` is always false and `Focus` is
  an empty function (fixed in CEF 156 by `dff7cc2c12`, chromiumembedded/cef#4301). So before, the new page lost focus:
  the panel was still first responder, so keys went in, but the caret was not drawn and `document.hasFocus()` was false.
  The sign-in password field on the next document, after the user name is submitted, is such a case (a user reported
  that the caret did not show in a password input). The host remembers Yardlet's last `focus` for each tab
  (`BrowserSlot.focused`), and whenever a new document commits in a frame (`on_load_start`), it gives `set_focus(1)`
  again if that value is true. Chromium passes the main widget's focus on to the page's other processes (iframes)
  (`ReplicatePageFocus`), and Blink does nothing if focus is already there. If the panel does not have the keyboard,
  focus is not given. After upgrading CEF to 156 or later, CEF does the same thing, but leaving this in place only gives
  the same value again.
- Navigating from the address field with Enter or the open button gives the page the keyboard (2026-10-24, Chrome's
  `BrowserUiController::UpdateUIForNavigationInTab` → `SetInitialFocus`). Before, the keyboard was nowhere, so an
  autofocus field had no caret and typing did not reach the page. If the address cannot be opened (URL policy), the
  keyboard stays in the address field.
- Input timestamps: CEF's macOS path reads the timestamp of the key, mouse and wheel events it is handed from
  `[NSApp currentEvent]`, and uses 0 if there is none (`browser_platform_delegate_native_mac.mm`). While it hands over
  input, the host returns an event with the current time (`CLOCK_UPTIME_RAW`) as `currentEvent`
  (`YardletBrowserHostApplication`, 2026-10-24). Before, in QA, key events were stamped 1.8–4.1 seconds late (mouse
  events were right), and when an SPA navigated on input stamped earlier than the page had opened, Blink's soft
  navigation CHECK ended the renderer (section 3, "Renderer exit").
- Shortcuts (when the panel view has focus): ⌘C/⌘X/⌘V/⌘A/⌘Z/⇧⌘Z, ⌘+/⌘−/⌘0 zoom in and out, ⌘F find, ⌘L address field, ⌘R
  reload, ⌘[/⌘] back and forward. Tabs (only when the window's focus is on the page): ⌘T new panel browser tab, ⌘W close
  this tab (the panel tab closing rule), ⌘⇧T reopen a closed tab as a new tab, ⌃Tab and ⌃⇧Tab next and previous browser
  tab, ⌘5…⌘8 that tab, ⌘9 last tab. ⌘1–⌘4 go to the window's keys (task panels) first. Outside the page (the
  conversation, the address field) the same keys go to the window's task tab strip.
- Drag and drop: files from Finder can be dropped on the page (`drag` command → CEF drag target). Dragging out of the
  page is not supported.
- Emulated screen size (2026-10-26, section 3, "Screen size emulation"): while the panel draws the page shrunk, the
  positions of mouse, wheel and drag and drop are converted to page coordinates with `pagePoint`, and the places of the
  input method's candidate window, context menus and VoiceOver elements with `viewRect`. Clicks outside the emulated box
  are not sent to the page. `<select>` lists (the popup layer) are inside the page layer, so they shrink with it.
- Cursor shapes, `title` tooltips, `<select>` lists (the popup layer), right-click menus (CEF's menu model as an
  `NSMenu`).

## 5. Accessibility (VoiceOver)

Because rendering is windowless, Chromium does not create macOS accessibility objects (the "TreeOnly" mode in CEF's
documentation). Yardlet receives CEF's accessibility tree and rebuilds it as `NSAccessibilityElement`s. The construction
follows the same approach as cefclient's OSR accessibility (`osr_accessibility_helper`, `osr_accessibility_node`). But
the cefclient source is not in the minimal distribution, so it was not downloaded; field names and units were checked by
recording real CEF output.

**Flow.** For each panel, a `BrowserAccessibilityBridge` attaches to `BrowserHostView.accessibilitySource`.
1. Turning it on sends the `accessibility(tab:isEnabled:)` command. The host calls `set_accessibility_state`.
2. CEF calls `on_accessibility_tree_change` and `on_accessibility_location_change`. CEF does not pass the browser to
   these handlers, so the bridge keeps a separate client, render handler and accessibility handler for each tab to tell
   the tabs apart.
3. The bridge builds JSON with `cef_write_json` (about 80 ms for 10 MB on a large page, on the CEF UI thread).
4. On a separate serial queue, the host keeps only the needed fields with `CEFAccessibilityReducer` and sends them as
   `accessibilityTree` and `accessibilityLocations` events.
5. The engine's `BrowserAccessibilityTree` applies them by Chromium's rules. Nodes are replaced whole, `clear` removes
   descendants, unreachable nodes are removed, and iframe documents are kept as separate trees. An iframe tree that
   arrives before its parent is kept too.
6. The bridge creates elements and posts notifications.

**On only when needed.** It is turned on only when:
- VoiceOver is on.
- An accessibility client has asked for the panel view's children, the element at a point (hit test) or the focused
  element.

It is turned off and the tree dropped when:
- VoiceOver is off and nothing has asked for 60 seconds.
- The panel was closed.

Until it is turned on, the renderer does no accessibility work. In QA there were 0 tree changes before the first query,
and asking again after it was turned off brought the whole tree again. When another accessibility app (a window manager,
an automation tool and so on) asks about the inside of the panel, it turns on then too.

**Fields kept.**
- Role, name, value, description, placeholder, role description
- States: focusable, editable, expanded/collapsed, hidden, ignored, multiline, protected, required, visited and so on
- checked/selected/disabled, `haspopup`, heading level, table and set positions, range values, text selection, link URL
- Child frame trees, children, location (device pixels relative to the offset container), scrolling

Dropping the inline text boxes made for every line (including their per-character position lists) cuts the size the
most. CEF output has no DOM node numbers.

**Exposure rules (engine).**
- Unwrapped into the parent: unnamed generic containers, paragraphs, labels, forms and rowGroups, and iframe documents.
- Left out: hidden (invisible) subtrees, list markers, line breaks.
- Kept as elements without children: roles whose content is only their name, such as buttons, checkboxes, text inputs
  and selects.
- Text used as the name: links, headings, list items and table cells that hold only text.
- A select's options (`menuListOption`) are not kept as children; the select exposes them separately.

**Roles.**
- Basic roles: button, link, text field and text area (secure and search subroles), checkbox (switch and toggle), radio,
  pop-up button (select), combo box, heading (`AXHeading`, its value is the level), static text, image, list, table, row
  and cell (row count, cell position), slider, progress, tab, menu, toolbar, tree.
- Landmark subroles: banner (`header`), navigation, main, footer (`footer`), complementary, search and region; article,
  alert, dialog.
- Roles AppKit does not describe (headings, landmarks and so on) get their role names directly, in Korean or English.

**Coordinates.**
1. Starting from the node's location, walk up the offset containers, adding their positions and subtracting each
   container's scroll (Chromium's rule). The result is page coordinates in device pixels.
2. Divide by the scale to get view coordinates, then convert through window coordinates to screen coordinates. An iframe
   document continues from that iframe's position.

Chromium does not send ordinary scrolling into the tree. CEF's location changes arrive as an empty list, and the root's
`scrollY` comes again only when the size changes. So the host sends `on_scroll_offset_changed` as a
`scrollOffset(tab:x:y:)` event (view points), and the tree uses this value until the root comes again. In QA, the frames
of positioned elements, of elements after scrolling and of elements inside an iframe differed from the page's
`getBoundingClientRect` by 0.00 pt.

**Notifications.**

| Notification | When it is posted |
|---|---|
| `layoutChanged` | After a structure change (at most once per 150 ms) |
| `valueChanged` and `titleChanged` | For elements whose value or name changed |
| `focusedUIElementChanged` | When focus changes and the panel view is first responder |
| `uiElementDestroyed` | For elements that went away (when there are 20 or fewer) |

**Actions.**
- AXPress: if the element is off screen, scroll the page, then click the element's center as mouse input to the panel. A
  select opens its options as a native `NSMenu`.
- Setting focus (`AXFocused`), setting a text value (`AXValue`), choosing in a select, `AXScrollToVisible`: the CEF tree
  has no DOM node numbers, so the element is found by position. If needed, the page is scrolled, and then a single
  `Runtime.evaluate` acts on the DOM element at the element's center. A value is set by selecting all and then
  `insertText`, so the page's input events fire. A select sends input and change events.
- Same-origin iframes are followed into. Inside a cross-origin iframe, only AXPress works.

**Cost** (QA, scale 2).

| Page | CEF JSON → size sent | Processing time |
|---|---|---|
| Small form page (107 nodes) | 45 KB → 15 KB | 27 ms from the first query to the tree, 2 ms to apply |
| Page with 18,020 nodes (10,009 exposed) | 10.0 MB → 2.9 MB for one change (the full tree came twice during loading) | Host processing 0.56–0.64 s (on a separate queue), Yardlet apply 63 ms |

Other figures for the large page:
- Longest stall of Yardlet's main thread: 66 ms. It was 325 ms before decoding moved to the pipe queue.
- 1.6–1.7 s from the start of loading until the tree is usable.
- 42 ms for one walk of the exposed tree, 220 ms to read every attribute of the 10,009 elements.

## 6. Agent-side API (engine)

The agent browser tools and the Yardlet MCP server use `MacBrowserHost.shared.client` (`BrowserHostClient`).

| API | Use |
|---|---|
| `openTab(forSession:url:viewport:)` | Gets the task's front tab: that tab if there is one (without reopening the page), otherwise it opens one (starting the host too). Opened without a panel, it uses `BrowserViewport.offscreenDefault` (1280×800, 2x) |
| `tab(forSession:)` | The task's front tab (the tab the panel shows) |
| `agentTab(forSession:)` | The tab agent tools without `tabId` use: the agent's active tab where it has one apart from the front tab, else the front tab (section 3, "The tab the person uses") |
| `tabs(forSession:)` | The task's tabs (in strip order, the same as the order of the panel's browser tabs) |
| `tab(key:forSession:)` | The tab of a panel tab key |
| `newTab(forSession:url:viewport:select:key:after:)` | Opens a tab at the end (or right after `after`). If `select` is false, it stays behind the front tab. `key` is the panel tab it becomes (a new key by default). With 9 tabs, `BrowserTabLimitError`; if a tab with that key already exists, `BrowserTabKeyInUseError` |
| `select(_:)` / `BrowserTab.select()` | Brings the tab to the front |
| `show(_:)` | The panel shows the tab (the person's choice, or the panel following the engine): it comes to the front, and an agent that worked in the front tab during its turn keeps that tab as its active tab |
| `selectForAgent(_:)` | The agent's choice (`browser_tab_select`, a new tab in front): while the person uses another tab in the panel, the panel stays and only the agent's active tab changes; returns the person's tab |
| `personUse(of:)`, `personUsedTab(forSession:)`, `setPanelKeyboard(_:on:)`, `personUseWindow` | Whether the person is using a tab (a panel on screen, the page's keyboard, input within 30 seconds) |
| `personWait(of:)`, `onPersonWaitsChange` | What a tab waits on from the person (a handoff, a Chromium window, a permission, another app, a JS dialog, a file chooser), and when that changes (section 3, "Tabs that wait on the person") |
| `agentUsedTab(forSession:)`, `endAgentTurn(forSession:)` | The tab the agent used last in its turn (the panel tab's mark); the end of the turn (clears the agent's active tab and the mark) |
| `closeTabs(forSession:)` | Closes all of the task's tabs and forgets their addresses (archive or delete) |
| `replace(_:url:)` | Replaces a tab that is not responding with a new tab with the same key, position and front state (not put in the closed-tab list; if a hang callback is held, the renderer is ended first) |
| `waitForPage(_:)` | The Wait action for a tab that is not responding (reports it again if it still does not respond after 15 seconds) |
| `rememberedTabs(forSession:)`, `restoreTabs(forSession:viewport:)`, `rememberTabs(_:forSession:)`, `reopenClosedTab(forSession:viewport:)` | Reopen the tabs lost when the host died or ended (including at app quit), or the tabs saved with the task before an app restart, with their order, front tab and keys (`BrowserRememberedTabs.keys`). Reopen a closed tab with a new key |
| `addTabsObserver(forSession:_:)` / `removeTabsObserver` | Called when a tab opens or closes, the front tab changes, a title, address or icon changes, or loading starts or ends (not for frames or other loading states). Used by the panel and by panel tab sync |
| `popupOpened` and `newWindow` events → `openedTab` event | A page's new window. A window the host created (`popupOpened`) is taken by the client as a task tab; a request the host did not create (`newWindow`) opens a new tab. The opening tab gets `openedTab(tab:newTab:url:)` (`newTab` nil outside a task or with 9 tabs). The agent tools report it in their next result |
| `noteAgentActivity(forSession:)` / `BrowserTab.noteAgentActivity()` | Called whenever the agent uses the browser. Keeps the tab visible to the engine for `agentVisibleWindow` (60 seconds) even without a panel, and shows an "Agent" mark in the panel header for 4 seconds |
| `BrowserTab.devTools` | CDP client (`send(method:params:session:timeout:)`, `nextEvent`, `events`). Since 2026-10-26 also `attachFrames()` and `frameSessions` (sessions of cross-site frames, section 3) |
| `BrowserTab.emulate(_:)`, `emulateColorScheme(_:)`, `endAgentEmulation()`, `emulation`, `onEmulationChange` | Screen size and color scheme emulation (section 3, "Screen size emulation") |
| `BrowserTab.handOff(reason:)`, `answerHandoff(_:)`, `endHandoff()`, `handoff`, `onHandoffChange` | The handed-over state of `browser_handoff`. The panel bar answers it and the agent's wait reads it |
| `BrowserTab.addEventObserver(_:)` / `removeEventObserver(_:)` | Receives events separately from the panel's `eventHandler` (dialogs, downloads, addresses and so on) |
| `BrowserTab.key`, `unresponsive`, `currentURL`, `lastPageURL`, `title`, `favicon`, `isLoading`, `canGoBack`, `canGoForward`, `session`, `isPanelAttached` | State (the panel reads it when it brings a background tab to the front) |
| `attachPanel(to:)` / `detachPanel(from:)` | Panel only |
| `openTab(url:viewport:)`, `closeTab(_:)`, `BrowserTab.close()` | Tabs without a session (kept until closed) and explicit closing. Names kept as they were in the second trial |
| `accessibility(tab:isEnabled:)` command, `accessibilityTree`, `accessibilityLocations` and `scrollOffset` events | Used by the panel's accessibility bridge (section 5). The agent tools can use the CDP `Accessibility` domain separately |

When a page opens a JS dialog or file chooser, its tab holds it (`BrowserTab.javaScriptDialog`, `fileDialog`) until
someone answers with `javaScriptDialogResult`/`fileDialogResult`, the page goes or the tab closes; a dialog pauses the
page's scripts meanwhile. A panel that shows the tab draws the dialog over the page and opens the chooser (section 3).
The agent tools receive the `javaScriptDialog` and `fileDialog` events through `addEventObserver` and can answer them.
Whichever side answers, the tab sends the other the client-made `dialogClosed(tab:dialog:)`, so the panel's dialog goes
and the agent does not take a dialog the person answered as still open. (Before 2026-10-27 the panel showed a sheet,
the sheet stayed when the agent answered first, and the agent kept taking a dialog the person had answered as open.)

## 7. Build and signing

- `scripts/build-app.sh` uses a pinned CEF: `154.0.28+g564dd6c+chromium-154.0.8037.58`, macOS arm64 minimal, official
  distribution SHA-1 `f7c50c2719deb8aa0c78de517c1228d0b8c3fced`, framework executable SHA-256
  `e2f817695b598f92dcc671238e508a7d7b984983072c36d5257d6c67ff776112`. It verifies and uses the unpacked distribution in
  `~/Library/Caches/Yardlet/CEF/`, and if only the archive is there, it checks the SHA-1 and unpacks it. If neither is
  there, it shows the download command and stops.
- Release bundles always include CEF. Only debug builds can be made without CEF, with `YARDLET_WITHOUT_CEF=1` (the panel
  is the WebKit preview).
- The script sets `YARDLET_CEF_DIR`, so `Package.swift` includes the host and helper targets. Without this variable
  (`swift build`, `swift test`) those targets are left out.
- `scripts/sign-app.sh` signs the assembled bundle from the inside out: the framework's dylibs → the framework → the 5
  helpers → the host → the MCP executable → the app. Each bundle is signed with the identifier in its own Info.plist, so
  QA copies (`prepare-qa.sh`) take the same path.
  - Ad-hoc (the default, with no `YARDLET_SIGNING_IDENTITY` or with `-`): the same as before. Each part has an
    identifier-based designated requirement (`com.zzunkie.yardlet.helper`, `….helper.gpu` and so on,
    `com.zzunkie.yardlet.browser-host`, `com.zzunkie.yardlet.mcp`), no hardened runtime.
  - Certificate (a name, part of a name or a SHA-1 in `YARDLET_SIGNING_IDENTITY`): each executable gets the hardened
    runtime (`--options runtime`) and the entitlements in `Packaging/Entitlements`. This follows the signatures in the
    Chrome 155 bundle and Chromium's `chrome/installer/mac/signing/parts.py`: only the Renderer and GPU helpers get
    `com.apple.security.cs.allow-jit`; the other helpers (default, Alerts, Plugin) and the MCP have no exceptions; the
    host gets `com.apple.security.device.bluetooth` and `…usb` for passkeys; the app gets `…bluetooth` because it is
    responsible for the host's Bluetooth; and, because permission requests from commands the app starts (harnesses,
    their tools, terminals) count as the app's in macOS, the app gets `com.apple.security.automation.apple-events`,
    `device.audio-input` and `device.camera`, with Info.plist usage description strings (Claude Code declares Apple
    Events and the microphone, and the Claude app, the Codex app, VS Code, Cursor and cmux have the same three. Without
    the entitlement, tccd refuses a hardened runtime app without asking). Libraries follow the hardened runtime of their
    process. Developer ID certificates sign with a secure timestamp (`--timestamp`, Apple's timestamp server), other
    certificates without one (changed with `YARDLET_SIGNING_TIMESTAMP`). For notarization, `scripts/notarize.sh` (README
    "Signing and notarization") first checks every Mach-O for Developer ID, timestamp, hardened runtime and no
    `get-task-allow`, and checks the notarytool keychain profile (default `yardlet-notary`; if it is missing, the script
    shows the `store-credentials` command and stops). It then submits the app (zip) with `notarytool submit --wait` and
    staples it, signs a DMG holding that app and an /Applications link with the app's certificate, submits and staples
    that too, and checks both with `spctl`.
  - Profile (`YARDLET_PROVISIONING_PROFILE`): added as the host's `embedded.provisionprofile`. The script checks that
    the profile's App ID is `<team ID>.com.zzunkie.yardlet.browser-host`, that its team matches the signing certificate
    and that it has not expired, and adds `com.apple.application-identifier` and `com.apple.developer.team-identifier`
    to the host's entitlements. The app itself uses no restricted entitlements, so it needs no profile.
    `keychain-access-groups` for Touch ID is added only when the groups the CEF framework expects
    (`scripts/cef-webauthn-group.sh list`) start with this team's prefix. In the distribution they are
    `.org.chromium.Chromium.webauthn` and `…-uvk`, so it is not added (if it were, the profile would not allow it and
    AMFI would block the host from running).
  - Touch ID prototype (`YARDLET_PATCH_CEF_WEBAUTHN_GROUP=1`, only together with a profile, off by default): in the copy
    of the CEF framework placed in the bundle, it changes the two constants to `<team ID>.com.zzunkie.webauthn` and
    `…-uvk` at the same lengths (31 and 35 bytes) (the downloaded distribution and its pinned hash stay as they are),
    and adds those groups to the entitlements. In a QA build changed to a fake team ID, it was confirmed that the
    "Expected value" in host.log becomes the changed group. Real Touch ID registration and sign-in succeeded on
    2026-10-23 in a QA bundle signed with the real team's Developer ID profile, with the user's Touch ID fingerprint.
    This approach of changing binary constants is still an explicit opt-in, and it is off by default.
- Updates: if the installed app has a team signature (Developer ID), `stage-update.sh`, Install Update… and the install
  script require the new build to meet the installed app's designated requirement (the same identifier, the same team)
  (the same rule as Sparkle). An ad-hoc installed app accepts any Yardlet build with a valid signature, as before.
- To move to a new CEF: change the version, URL and both hashes, confirm by starting the host that the C API hash
  (`CEF_API_VERSION`) matches, and run `scripts/browser-host-qa/run-check.sh`.

## 8. File locations

| Path | Contents |
|---|---|
| `~/Library/Application Support/Yardlet/Browser/Default` | Default profile (cookies, storage, cache): tabs without a task, "Shared by all tasks", starting cookies for new tasks |
| `~/Library/Application Support/Yardlet/Browser/Task-<key>` | Per-task profiles (Chromium opens only folders directly under the root cache as disk profiles). `TaskProfiles.json` holds the new-task screen's key and the key of the task that took over its tabs. Folders that do not belong to a remaining task are deleted when the host ends, along with the records Chromium kept for those profiles in `Local State` (`profile.info_cache`, `profile.profiles_order`, `variations_google_groups`) |
| `~/Library/Application Support/Yardlet/Browser/AddressHistory.json` | The address field's history of every task's tabs: pages with their visits and titles, and past searches (section 3, "Address suggestions") |
| `~/Library/Application Support/Yardlet/Browser/Home` | The host's `CFFIXED_USER_HOME`. Files Chromium writes outside the cache path (`CEF/User Data`, `Google/RLZ` and so on) collect here |
| `~/Library/Application Support/Yardlet/Browser/Logs/host.log` | Host standard error (starts over past 4 MB), `chromium.log` |
| `~/Downloads` | Downloads |
| `$TMPDIR/<bundle id>.browser-host.*` | Chromium's temporary folders (the OS cleans them up) |
| `/var/folders/…/X/<host bundle ID>.code_sign_clone/code_sign_clone.XXXXXX` | A copy of the host bundle Chromium makes when a host starts (an APFS clone with only the executables hard-linked). It keeps the running host's signature valid when an update replaces the bundle. When the host ends, Chromium's cleanup Helper deletes it (section 3, "Shutdown"). Copies from hosts that were forced to end remain, and macOS dirhelper deletes them after 3 days. Once the copy exists, the host's executable path that the kernel reports (`proc_pidpath`) can point into the copy |

## 9. Security

- Frames are received over Mach. For each run, Yardlet does a bootstrap check-in under the name
  `"<bundle id>.browser-host.<pid>.<128-bit random>"` and passes the name and a 256-bit token to the host in environment
  variables. For each received message, it checks that the PID in the kernel-attached audit token is the host it started
  and that the token matches, and drops the message otherwise (in QA, 2 forged messages Yardlet sent itself were
  rejected). Even with the installed app and a QA app running together, the names do not collide.
- The host's write pipe has `F_SETNOSIGPIPE`, so Yardlet does not end with SIGPIPE if the host dies.
- The helper sandbox is on. If the framework and helpers are outside the host bundle, the sandbox stops the GPU helper
  from loading the framework.
- URL policy, new windows and the quarantine attribute on downloads: section 3. Certificate errors use CEF's default (a
  blocking page); HTTP authentication windows are not supported.
- The mock keychain trade-off: section 3.

## 10. Known limits

- **Accessibility:** moving element by element (VO+arrows), reading, pressing, focus, setting values, choosing in a
  select, and scrolling into view work (section 5). The following do not:
  - VoiceOver web navigation: the rotor's heading and link lists and quick navigation
    (`AXUIElementsForSearchPredicate`), and moving by character, word and line with text markers. This is why the root
    is exposed as a group rather than an `AXWebArea`.
  - Live region announcements, slider increment and decrement (AXIncrement/Decrement).
  - Scrolling scroll areas inside the page, and reflecting CSS transforms in positions: elements show at their previous
    position until redrawn.
  - Focus and setting values inside a cross-origin iframe.
- **Profile lock:** when two Yardlet instances using the same user home (for example the installed app and a development
  build) open the browser at the same time, the second host cannot start because of Chromium's profile lock
  (`cef_initialize returned 0`, "Opening in existing browser session." in the log). This is why QA runs use separate
  temporary homes.
- **Lag while the width changes:** while the panel's width is dragged, the page follows late, by the time the renderer
  takes to lay out and draw at the new width. When widening, a white strip shows on the right; when narrowing, the right
  of the page looks cut off; both settle once the drag stops (QA `resize`, dragging about 7 pt every 16 ms; median
  difference between panel width and page width: 8 pt on a light page and 31 pt on a page with 3,000 post cards; time to
  settle after stopping 16 and 95 ms). CEF sends only one size change at a time to the renderer (`hold_resize_`), and
  the windowless view has no mechanism, like a Chrome window has, for waiting for a frame at the new size before drawing
  the window.
- No trackpad edge bounce (rubber-band) and no swipe to go back (CEF wheel events carry no phase information). No smart
  zoom (double tap) either.
- Web notifications do not show. Since 2026-10-25 the browser process starts with
  `--disable-features=NativeNotifications` (`disable_native_notifications`, appended to `disable-features` among the
  extra switches), so Chromium does not create the system notification bridge. Before that, at every start, to reconcile
  past notifications, it connected the banner service (the host itself) and `Yardlet Helper (Alerts)` to macOS
  notifications and asked for permission, so each QA bundle with a new bundle ID put a permission request on the
  person's screen. There is no public CEF API that passes web notifications on as Yardlet notifications.
- No dragging out of the page, no extensions, no DevTools window.
- Since the evening of 2026-10-25, camera and microphone ask through the permission bar (section 3, "Permission
  requests"). QA checks only up to Block on the bar, because allowing would put the macOS permission window on the
  person's screen. So the step where macOS asks after allowing, real video and sound, and whether the host's
  entitlements are used in a signed installed app (Yardlet itself has had them for some time) were not verified. Screen
  sharing (`getDisplayMedia`) is denied, since there is no window to pick from. Location and notifications can be
  allowed on the bar, but the step where macOS asks after that and whether notifications actually show were not verified
  (the host and Yardlet have no location usage description).
- Since the evening of 2026-10-25, external app addresses (`mailto:`, `tel:`, `zoommtg:`, `slack:` and so on) open or
  ask as in Chrome (section 3, "External app addresses"). Remaining differences: (1) When such an address is typed into
  the address field, Chrome opens the app, but Yardlet blocks it as before. (2) "Always allow" is stored in the tab's
  profile, so with per-task profiles it is per task (Chrome has one profile). (3) Requests that come from the agent's
  input ask the person even for mail links and sites set to "always allow" (Chrome has no agent). Whether a real mail
  app, FaceTime or Zoom opens was not checked in QA (the opening function is swapped for a recorder).
- Pop-ups without a user gesture are not opened, as in Chrome (`window.open` returns null), and since the evening of
  2026-10-25 they open from the "Pop-ups blocked" list at the right of the address field (section 3, "New windows"). A
  tab opened that way has no `window.opener`, and there is no "Always allow pop-ups from this site". A window a page
  opens within 5 seconds after a user gesture counts as having a gesture (Chromium's transient activation).
- Since the evening of 2026-10-25, Chrome's "Leave site?" question on closing a tab is asked when the person closes the
  tab in the panel (section 3, "JS dialogs"). The agent closing a tab, archiving or deleting a task, and quitting the
  app close without asking (Chrome also asks when a window is closed or the app quits). A page that does not answer
  within 1 second is closed without asking.
- `showDirectoryPicker()` arrives as the file open window. This is because CEF does not handle folder selection
  (`ui::SelectFileDialog::SELECT_FOLDER`) (NOTIMPLEMENTED in `file_dialog_manager.cc`, which opens in the default mode).
  `<input webkitdirectory>` gets the folder window.
- Full screen (`requestFullscreen`) works only within the panel's page area. It does not make the window full screen (no
  CEF `on_fullscreen_mode_change`).
- Remaining differences in password fields (secure input and the Roman input source limit since 2026-10-25, section 4):
  (1) Unlike Chrome, the Claude app and the Codex app, Yardlet does not turn off the input method itself (`inputContext`
  nil). Composing input methods such as Korean and Japanese drop out through the Roman input source limit, and dead key
  composition in Roman input sources stays, as in Safari. (2) If a script changes `type` while the field has focus (a
  "show password" button that does not move focus), the previous state stays until the next focus change. Chrome also
  treats a field that was once a password field (`TEXT_INPUT_FLAG_HAS_BEEN_PASSWORD`) as a password field, and CEF's DOM
  API does not give that flag. (3) Whether the real input source switches to Roman and comes back on leaving the field
  could not be seen in QA. It happens only in the frontmost app, the QA app does not become the active app, and to avoid
  changing the person's input method, QA only checks the order of turning on and off with a recorder
  (`BrowserSecureInputRecorder`) (section 11).
- Passkeys: there is no iCloud Keychain, and Touch ID exists only in builds made with the prototype in section 7 (for
  the reasons in section 3). An immediate request for which the site has no passkey goes straight to the QR sheet, as in
  Chrome (section 3, (2)). Since 2026-10-27, QA checks placing the dialog over the panel and raising it again in front
  of the Yardlet window through the window server's front-to-back order (section 3, "Chromium's windows and tabs"). Real
  clicks and handing over activation could not be run in QA (the QA app starts in the background and does not become the
  active app; the rules are in `ChromiumWindowPresentationTests`). Registering and signing in end to end with a real USB
  security key or phone has not been confirmed either.
- Up to 9 tabs per task. If the agent uses the tab the user is looking at, input can mix (the agent can work in a
  background tab with `browser_tab_new`). There is no dragging tabs to reorder, detaching a tab into a window, renaming
  tabs or muting (the Codex app has them). With focus on the page, ⌘1–⌘4 do not select tabs (the window's keys get them
  first). Icons are not saved, so after a restart a tab shows a globe until its page opens.
- New windows (section 3, "New windows"): pop-ups without a user gesture are not opened, and window size requests are
  not used; the window opens as a tab. In a task with 9 tabs, or for a tab outside any task, the opening tab goes to the
  address, so there is no `window.opener` in that case.
- No card or address autofill (save offers, filling saved entries, form history) (section 3, "Autofill save offers").
  Chrome's screens for these attach to a browser window. Since the evening of 2026-10-25, Payment Request (Google Pay
  and Apple Pay buttons, Secure Payment Confirmation) is not available to pages (section 3, "Payment API (wallet
  buttons)"). Before, `show()` did not bring up the payment sheet and ended with
  `AbortError: Cannot show PaymentRequest UI in a preview page or a background tab.`. Chromium shows the sheet only when
  the tab's Chrome window is active (`ChromePaymentRequestDelegate::IsBrowserWindowActive`). So sites that take payment
  only through wallets cannot be paid on, while payments where a card is entered work.
- JS dialogs and file choosers of a tab no panel shows stay open until the agent answers or the person shows the tab
  (section 6; section 3, "Tabs that wait on the person"). Permission requests wait until the panel shows that tab (the
  agent cannot answer them). Download notices also show only when there is a panel.
- QA has not seen the chooser placed over the page as a child window of the panel's window: the system's window would
  appear on the person's screen, so QA uses a recording presenter instead (section 11, `person-first`). A passkey window
  still takes the keyboard when it is placed while Yardlet is in front (`ChromiumWindowPresentation`), so one that the
  agent's click opened can take what the person was typing. That is unchanged, since a security key's PIN and Escape need
  the keyboard.
- **One dialog log line (before 2026-10-22, when new windows opened in the same tab):** for a `window.open` with a user
  gesture, the host cancelled the new window and opened it in the same tab. Afterwards, on that page's next main-frame
  navigation, CEF logs `Default dialog implementation requires a parent window handle; canceling the JS dialog` once. In
  QA it showed only after a `window.open` called through CDP, and not after a `target=_blank` link that was actually
  clicked.
  - None of Yardlet's four JS dialog handlers (on_jsdialog, on_before_unload_dialog, on_reset_dialog_state,
    on_dialog_closed) is called.
  - It remains when the way of opening in the same tab changes: `load_url` inside the callback, `load_url` deferred
    until after the callback, `location.assign` on the page side, or not opening at all.
  - The navigation proceeds and the user sees nothing. So it is taken to be not a dialog that could be sent to Yardlet
    but CEF's internal handling of the cancelled new window. Finding out more would need the CEF source or a verbose log
    (not in the minimal distribution).
  - In QA, the DEBUG host logs commands and dialog handling with timestamps so they can be compared.
- Each host logs one line `sandbox_extension_issue_file_to_process failed … Operation not permitted` at start. No effect
  on features has been seen.
- Shutdown hang (2026-10-24): in 3 of 8 full QA runs, a heavily used first host, on `shutdown` after the grace period,
  ended Chromium's child processes and then did not return from `CefShutdown` (no stats line, and before the copy
  cleanup Helper even started). Yardlet ends it with SIGKILL after 5 seconds, so only that host's copy remains. The
  cause was not found (no sample of a hung host had been taken yet). On 2026-10-25,
  `--ui-fixture-browser-check-only=tabs` hung the same way twice in a row when quitting with 2 tabs open (host.log ends
  at `command shutdown`, and the `closed` for both open tabs came). This can serve as a way to reproduce it. In the
  first sample of a hung host, taken on 2026-10-25 (a QA home under the worktree's `~/Desktop/…/.build`, `compat`), the
  main thread was waiting inside `yardlet_cef_shutdown`, and three Chromium worker threads were blocked for the whole
  sample on two `getxattr` calls (`NSURL getResourceValue:forKey:`) and one `link` on profile files. All five `compat`
  runs under `~/Desktop` left copies, and running the same build with the QA home under `$TMPDIR` shut down normally
  (stats line, no copy). The cause in QA is taken to be macOS's Desktop folder protection (section 11; the QA app's
  `open()` also hung there). The installed app's profile is under `~/Library/Application Support`, so it is not expected
  to be affected, but this was not verified.
- Frame delivery: the host sends each new IOSurface in a Mach message without waiting (if the queue is full, only that
  frame is dropped), and Yardlet receives frame events on the pipe queue as they come (section 2). Before, in tabs
  without a panel the queue filled up and blocked the CEF UI thread for 1 second per frame, so CDP ran seconds late.
- Copying for accelerated drawing: the IOSurface from `on_accelerated_paint` cannot be used outside the callback (CEF's
  pool), so the host copies it into its own ring with a Metal blit and waits for it to finish. In 2026-10-22 QA
  (840×1536 px, a 120 fps animation for 3 seconds), of 1,497 CEF UI thread samples, 399 were in the callback, 216 of
  them waiting: about 0.6 ms per frame. Making it asynchronous with a completion handler could cut UI thread time
  further, but this has not been done yet.
- Scroll frame rate: on a 120 Hz display requestAnimationFrame runs at 120 fps, but wheel (precise deltas at 120 and 240
  events/s) and Page Down scrolling run at 60 fps (QA `run-perf.sh`). CEF OSR's BeginFrame runs at 120 Hz, so this looks
  like a rule in Chromium's compositor that halves frames for input scrolling; which feature it is (`cc` frame rate
  estimation, `viz` FrameRateDecider and so on) has not been found.
- The bundle is large: release 303 MiB (zip 134 MiB), 272 MiB of it the host.

## 11. QA

In a DEBUG bundle, the tools in `scripts/browser-host-qa/` check the real panel, host and CDP paths.

```sh
./scripts/build-app.sh
QA="$TMPDIR/browser-host-qa"; mkdir -p "$QA"
./scripts/browser-host-qa/prepare-qa.sh .build/Yardlet.app "$QA/Yardlet Browser QA.app" com.zzunkie.yardlet.browserqa
./scripts/browser-host-qa/run-check.sh "$QA/Yardlet Browser QA.app" "$QA/run1" \
    --ui-fixture-browser-grace=12 --ui-fixture-browser-accessibility-idle=6
./scripts/browser-host-qa/cleanup-qa.sh "$QA/Yardlet Browser QA.app" "Yardlet QA builds $(date +%F)"
```

`--ui-fixture-browser-check-only=browser-use` (2026-10-26, `BrowserHostBrowserUseQA`) checks the agent's use of the
browser: screen size emulation (presets, kept after a new load, reference clicks, screenshot size, color scheme, kept
after a full-page screenshot, desktop, a size larger than the panel drawn shrunk with the person's clicks landing in the
right place, end of turn, the person's menu), reading, reference clicks and typing in iframes and shadow DOM, handoff
(waiting, the panel bar, I'm done, Decline, text, time limit, end of turn), and the snapshot size for each QA page
(`snapshotSizes` in `result.json`).

The QA app starts with a separate bundle ID (including the host and helpers inside it), a temporary home,
`--ui-fixture=conversation`, `open -g` and `YARDLET_QA_BACKGROUND=1`. With that variable (`QABackground`) set, the app
is an accessory app that does not appear in the Dock, the menu bar or ⌘Tab, it does not become the active app, and its
windows are placed outside the bottom left of every screen. Notification clicks, Dock bouncing, update notices and
handing activation to the passkey window follow this variable too, and the host, which inherits the same variable, keeps
Chromium's windows (passkey) off screen and does not activate them (2026-10-24; before, the window appeared on screen as
"Yardlet", and the person could click it and type into it). Only `run-perf.sh` keeps the window on screen
(`--ui-fixture-browser-perf`), because it has to measure the display's frames, but it does not activate it. Run it when
the person is not using the Mac. The showcase capture (`scripts/showcase/capture.sh`, `--ui-fixture=showcase` and
`--ui-fixture-ignore-pointer`) also captures the window from the display, so it keeps the window on screen without
activating it; the window goes behind the person's windows, and clicks pass through it (2026-10-27). Whether it finishes
or is interrupted, `run-check.sh` ends the app it started and that app's process tree by PID, and records a failure if
any process inside the bundle remains. After it finishes, it also checks crash reports left by this QA bundle's
processes (`~/Library/Logs/DiagnosticReports`, picked out by the bundleID in the report's first line,
`crash-reports.txt`) and leftover host copies (section 8), and records a failure if there are reports other than for
renderers the fixture ended on purpose (`intentionalRendererCrashes` in `result.json`, `Page.crash` in `input`) or any
leftover copy (2026-10-24). With `YARDLET_PROVISIONING_PROFILE` set, only the host keeps its original App ID to match
the profile, and the app itself and the helpers change to the QA ID. The profile and CEF patch variables are passed
through to `sign-app.sh` unchanged. Cookies use QA's mock keychain, but Touch ID registration and authentication use the
real team's keychain group and the user's fingerprint (README "Signing and notarization"). `run-check.sh` measures the
process tree's memory and wakeups at each step, and at the end checks that no process is left. `cleanup-qa.sh` removes
the LaunchServices registration and moves the bundle and preferences files to a trash folder. It cannot remove
notification registrations (`usernoted`'s store cannot be cleared by any public means). So QA bundles are never
registered for notifications in the first place: the app itself does not use Notification Center under a QA ID or with
`YARDLET_QA_BACKGROUND`, and the host and helpers do not connect to macOS notifications, as described in section 10
above (2026-10-25). For the person to look at it, `qa-launch.sh` starts only the fixture and brings the window to the
front. A QA window started in the background can be covered by other windows, so `run-check.sh` and `run-latency.sh`
pass `--ui-fixture-browser-ignore-occlusion` (DEBUG) to make the panel draw regardless of occlusion (occlusion itself is
checked by `BrowserHostVisibilityTests` and the minimize step of `run-perf.sh`). Right before the last step, the agent
tools open `/tall` (4,086 px in an 800 px viewport, each band a different color) in a tab without a panel and capture it
with `fullPage`, then check that each band's center color appears once and in order, that the image is the page's size,
and that afterwards the tab's size and the page's `innerHeight` and height are unchanged (`fullpage-screenshot.png`,
2026-10-24). In the last step of `run-check.sh`, with the panel closed, the agent opens and uses a tab, while another
tab's size is changed 30 times so that surface IDs are reused, and then the panel opens. For each size it checks that a
frame of that size shows, and that the panel shows the agent's page at the panel's size. "tabs: side-panel tabs" (⌘T, a
tab the agent opened in the background, bringing that tab to the front and closing it, ⌘⇧T, closing) often failed from
2026-10-23 to 2026-10-25. The cause was not load but a race condition in the product. The pane
(`BrowserHostPaneController`) followed the tab the panel shows only through SwiftUI `.onChange(of: key)`, and SwiftUI
runs that action only once per frame and drops a second change in the same frame (system log
`onChange(of: UUID) action tried to update multiple times per frame`). In a QA window that is not drawn, frames rarely
advance, so two tab switches 30–60 ms apart were bundled into one frame, and the pane stayed on the previous tab or a
closed tab until the next switch came ("new tab in front false" and "pane key …/-1" in the failure text). Since
2026-10-25 the pane follows the workspace's `panels` directly with `withObservationTracking` (`followPanel`). Running
tabs alone, the build before the fix failed 12 of 16 runs (load average 5–10), and an intermediate fix failed 2 of 5,
and only the failed runs had that warning, one each. The fixed build passed all 8 runs (load average 8–24) and all 51
checks of the full run. If this step fails again, start with
`/usr/bin/log show --predicate 'eventMessage CONTAINS "multiple times per frame"'` for the same time.
`--ui-fixture-browser-check-only=input` (QA path `/login`) records in `input.json`: focus, caret (the caret column in
frame pixels) and typing in a plain field and a password field, focus after the same pane shows another tab, focus and
the password field caret after the page changes (new documents `/login?autofocus=pass` on the same site and on another
site (`localhost`), the cross-site iframe `/login-frame`, back, and Enter in the real address field) and navigation
while the panel does not have the keyboard (the page does not get focus), the age of input events the page received
(`performance.now() - event.timeStamp`), whether the renderer survives SPA navigation (pushState and new content) after
a click and after Enter, the page height while loading, and the header status and host.log line after `Page.crash`. The
same step also checks the password field's secure input (2026-10-25, section 4). The QA app (`QABackground`) and the
checks do not touch real secure input or input sources; they record the order of turning on and off with a recorder
(`BrowserSecureInputRecorder`, which counts the window as key): turning on and off, and turning off as many times as
turned on, on clicking a plain field and a password field, when the panel loses and regains the keyboard, on each page
navigation above (the password field in a cross-site iframe, a page restored from the back-forward cache
(`window.__restored` of `/login`), Enter in the address field), on a page without fields, on autofocus while the panel
does not have the keyboard, with two tabs each keeping their own field, on renderer exit and reload, on host exit and
reopening, and on closing the panel (`secureInput.calls` in `input.json`). While it runs, `run-check.sh` checks whether
this run's processes hold real secure input (`kCGSSessionSecureInputPID` at the IORegistry root) and records a failure
if they do (`secure-input.txt`).

Performance is measured with `run-perf.sh <QA app> <output>/perf-1` (`BrowserHostPerfFixture`). It moves the window to
the display with the highest refresh rate and sets it to 1400×900 (panel 420×768 pt), and writes to `perf.json`: from
opening the panel (cold, warm, a new tab in a running host) to the first frame; on `/large`, the frame count and the
delay from drawing to screen for precise wheel input at 120 and 240 events/s and for Page Down; the frame count of
`/animation` and the page's own rAF count; 2 seconds with the window minimized and after restoring; 40 changes of the
window height (time to a frame at the new size, footprint before and after); and the footprint after the panel is closed
and its tab hidden. For each step it keeps the process tree's CPU and footprint (`samples/`), and a host `sample` during
the animation. The QA home is `qa-home`, a sibling of the output folder. To keep homes from overlapping with another QA
running at the same time, use a different parent for the output folder (profile lock).

Latency is measured with `run-latency.sh` (`--ui-fixture-browser-latency`). On the real panel and host, both with the
main thread idle and with it as busy as the installed app while a task streams (a 17 ms block 28 times a second), it
records in `latency.json` the draw-to-screen delay and the interval between frames placed on screen for an animation
page, and the wheel-input-to-screen delay for a long page. Input is put onto the main queue from another thread, like
window server events.

```sh
./scripts/browser-host-qa/prepare-qa.sh .build/Yardlet.app "$QA/Yardlet Latency QA.app" com.zzunkie.yardlet.latencyqa
./scripts/browser-host-qa/run-latency.sh "$QA/Yardlet Latency QA.app" "$QA/latency1"
```

`--ui-fixture-browser-check-only=memory-saver --ui-fixture-browser-memory-saver=4 --ui-fixture-browser-agent-visible=1`
(2026-10-27, `BrowserHostMemorySaverQA`, section 3, "Memory saver") makes Chrome's 4 hours 4 seconds and keeps eight tabs of
one task with no panel: two pages that hold memory and have an iframe from another site (one moved on to a next page, so
its history has two entries), a page whose CSP allows no script of its own, a page playing sound, a form the person typed
into, a page that opened a pop-up and that pop-up (sharing one renderer), and a PDF. It checks that the first three are
discarded and the rest kept, each for its reason; the host's process count and footprint before and after
(`before`, `afterDiscard` and `afterRestore` in `result.json`; run-check.sh samples too at the phase markers `saver-1-live`,
`saver-2-discarded` and `saver-3-restored`); that the page loads again with its history (`history.length`) and Back when the
agent's tools use a discarded tab; that a panel showing a discarded tab loads it again; and that turning the setting off
loads the rest.
`--ui-fixture-browser-check-only=many-tabs --ui-fixture-browser-limit=20` runs through tabs of several tasks and a tab
with no room left in the browser (2026-10-27, section 3, "Number of tabs"). It opens 20 tabs: one panel tab, 9 tabs each
in two other tasks (each task with its own profile), and one tab the agent opened. It checks that tabs beyond 16 all
reach their pages and that the agent's 20th tab answers. Then it checks that when a 21st tab cannot open, the agent
hears the reason without waiting and the tab list says so, that the card shows the reason even when the panel shows that
tab after the failure, and that after a tab of another task is closed, "Try again" and `browser_navigate` open that tab
in its place. `--ui-fixture-browser-limit` (DEBUG) becomes the host's `--browser-limit` and lowers the bridge's limit
(`yardlet_cef_set_browser_limit`). The build before the fix (16 slots) failed six of the seven items. Tabs 17 to 19 did
not reach their pages, the agent's 20th tab got only "The browser tab is gone.", the tab list showed about:blank as
`responding:true`, and the panel card was empty (the same symptoms as in the installed app). For the last item, before
the fix the tab simply opened in the slot the previous step had freed, so it failed but did not reproduce the same
condition. The fixed build passed all seven items, and host.log had `tab not opened tab=21 reason=limit`.

`--ui-fixture-browser-check-only=resize` drags the side panel's divider the way a person does, changing the width every
16 ms, from the widest width to the narrowest, and back to two thirds (2026-10-27, section 3, "Frames during a resize").
The QA page `/responsive` has a red strip at its right edge and changes its number of columns with the width, and
`?heavy=1` adds 3,000 post cards to make layout heavy. Every 4 ms it reads the red strip's position in the frame on
screen, records whether that frame is the page laid out at its own size (not a frame shrunk with black bars) and the
difference from the panel width, and checks the time after stopping until the page is laid out at the panel width, and
the page's `innerWidth` and number of columns (`resize.json`, and the panel during and after the drag in
`resize-*.png`). With the build before the fix, of 404 samples taken during the drag, 73 on the light page and 89 on the
heavy page were frames shrunk with black bars; with the fixed build both are 0.

`--ui-fixture-browser-check-only=person-first` (2026-10-27, `BrowserHostPersonFirstQA`) checks the person's screen (section 3,
"Tabs that wait on the person" and "The tab the person uses"). A confirm that a page opened in another task's tab waits
in that tab without a window sheet; the task becomes "Waiting in the browser"; one notification is announced (QA sends
no notifications, so it reads `AppModel.browserWaitAnnouncements`) and that task's panel is left on the tab; and the
dialog is still open 2 seconds later. A confirm in a tab behind the panel's, in the same task, waits with the tab marked,
shows over the page when the panel shows the tab, hides when the panel goes to another tab and shows again on return,
and the person's OK reaches the page. A file chooser in a tab behind waits, opens when the tab shows, closes unanswered
when the panel leaves, opens again on return, and the chosen file reaches the page (with a recording presenter in place
of the system's window). A chooser the agent's click opened waits only in a bar and goes with the agent's
`browser_file_upload`. After the person clicks their tab, the agent's new tab in front, its navigation without a `tabId`,
its tab list and a tool on the person's tab leave the panel as it is and say so; once 8 seconds (the `personUseWindow`
QA shortens) have passed, the panel follows the agent's choice. Captures: `person-first-marked-tab.png`,
`person-first-dialog.png`, `person-first-agent-tab.png`.

`--ui-fixture-browser-check-only=address-suggest` (2026-10-27, `BrowserHostAddressSuggestQA`) checks the address
field's suggestions (section 3, "Address suggestions") with a fake Google suggest service (`FakeGoogleSuggest`), so no
request leaves the Mac. The person types the QA host twice and another page once and reaches a third by a link; then,
typed into the field's editor as the keyboard types: the first character over the page's address and the next complete
the host inline, selected after the caret; the verbatim search and Google's suggestions come before pages; the dropdown
lies over the page and takes the hit there; ↓ moves and puts the row's text in the field, Escape returns to the first row
and its completion; ⇧fn⌫ removes a page from the history; Return opens the completed host and counts it as typed again;
a row opens when pressed; turned off, nothing is asked of Google and history rows stay. The QA app is never active, so its
window takes no first click: a row is pressed through accessibility there. Captures: `address-suggest-inline-*.png`,
`address-suggest-selected-*.png`, light and dark.

`--ui-fixture-browser-check-only=tooltips` checks the names (tooltips) of the panel header buttons (2026-10-27). SwiftUI
answers `.help` with AppKit's dynamic tooltips. The window's hosting view has one tracking-area owner
(`TooltipBridge.DynamicTooltipManager`), which returns the name at the point where the pointer rests through
`dynamicToolTipStringAtPoint:trackingRect:`. The check calls that method every 2 pt along the rows above the page and
checks, in the panel beside the conversation, the expanded panel and the review panel, that every button name comes back
and that a hit-test at that point reaches the button (that neither the title bar nor the page takes it). It then runs
AppKit's own path from a resting pointer to a shown name for each button (`TooltipDisplayProbe`): the pointer's readings
are set to the button's middle and the window is taken as one of an active app, which a QA app never has; everything else
is AppKit's own reading, and the tooltip window is never ordered in. The same runs for names outside the panel: the
title bar's sidebar button and others in the sidebar and conversation. Last it checks that the display delay AppKit uses
(`NSToolTipManager`'s `_getDisplayDelay:inQuickMode:forView:`) is 0.2 seconds.

Names that came back here and still never showed under a real pointer, however long it rested, were held by the window
(2026-10-27). AppKit counts each scroll that starts in a window and each that ends
(`_disableToolTipCreationAndDisplay`, `_enableToolTipCreationAndDisplay`) and shows names only while the count is zero.
An animated scroll (SwiftUI's `withAnimation` scrolls, a mouse wheel's smooth scroll) counts its end only when it reaches
its target, so one that the person's own scrolling interrupts, or whose scroll view leaves the window, never does; nor
does a list scrolled just before it leaves the window. Every name in that window then stays hidden until it closes, while
a freshly launched app shows them all. `WindowTooltipRelease` brings the count back to zero when the pointer moves over a
window whose names have been held for 1.5 seconds with no scrolling in the last second, and AppKit then shows the name
where the pointer rests. The check holds the window's names as such a scroll does, checks that a header button's name
does not show, posts one pointer move, and checks that the names come back (after about 1.5 seconds) and show. An
earlier version of the check stopped at the names and the delay, and read the hidden names as late ones.
The same step first checks a page element's `title` too: whether resting the pointer on
`#tip` of the QA page turns CEF `on_tooltip` → the host's `tooltip` event → the panel view's `toolTip` into "Tooltip
text". The full check's "tooltip" item passed in the 10-25 run and failed in the 10-27 run; the cause was the check, not
the product. At the 10-27 panel width `#tip` (a `span` inside a paragraph) wrapped onto two lines, so the center of
`getBoundingClientRect()` was the center of the box around both lines, that is, over other text of the paragraph (the
hover reached only `P`, and Chromium sends no tooltip for text without a title). The QA's `center` now uses the center of
the element's first box (`getClientRects()[0]`).

`--ui-fixture-browser-check-only=external-links` checks links and HTML files other apps open with Yardlet as the default browser (2026-10-27, section 3, "Default browser"). The QA app hands a QA page address and an HTML file it writes to itself through Launch Services (`NSWorkspace.open(_:withApplicationAt:)` with `activates` off, so it stays in the background), as another app's link reaches the default browser, and checks that each opens at its page in a new tab of the side panel of the task the window shows, and that no window of its own opened. Launching the QA bundle registers it with Launch Services as a browser (its record has `claimed schemes: http:, https:` and the `com.apple.default-app.web-browser` claim), which does not change the Mac's default browser; `cleanup-qa.sh` unregisters it. Bringing the app in front and the window steps (out of the Dock, opened again) are not run: the QA app is never active. A link that launches Yardlet was checked by hand on 2026-10-27: the QA bundle launched in the background (`open -g -n -a <QA bundle> <address or HTML file> --args --ui-fixture=conversation`, the environment of `qa-launch.sh`) had one window, as a plain launch does, and started its browser host, which only a tab does; with the scene's `handlesExternalEvents(matching: [])` it had no window.

`--ui-fixture-browser-check-only=tabs` runs only the browser tabs of the side panel ("tabs: side-panel tabs"). At the
end it ends the host with tabs open, as on app quit (`terminateHost`), and checks the number of `closed` events the host
sent for its tabs and that the panel tabs and remembered tabs are unchanged ("tabs: quitting keeps the panel's tabs",
2026-10-25).

`--ui-fixture-browser-check-only=compat` runs, on the QA server's `/compat`, what ordinary sites expect of a browser
(2026-10-25, `exerciseCompat`). Checks: from the second download on the same page, the panel bar asks "Download multiple
files" and the files arrive once allowed (blob, data addresses, two at once); for a file address opened with
`target=_blank`, the empty tab closes after the download and the opening tab comes to the front; notification, location
and clipboard read requests show on the bar, and blocking them ends the page's request as denied (`denied`,
`PERMISSION_DENIED`, `NotAllowedError`); a PDF opens in Chromium's viewer (the tab title is the file name); a
self-signed certificate shows Chromium's warning page instead of the panel card, and Advanced → Proceed opens the page.
Checks added on the evening of 2026-10-25: there is no `PaymentRequest` and the page hides its wallet buttons; a pop-up
without a user gesture stays as one entry in the panel's "Pop-ups blocked" list and opens from there as a new task tab;
camera and microphone requests show on the bar, blocking ends them as denied, and a repeated request is denied without
asking; other apps' addresses follow Chrome's rules (a mail link opens without asking, a mail link opened in a new tab
leaves no tab, a phone link shows "Open FaceTime?" with the "always allow" box, does not open on Cancel, and opens
without asking after "always allow" and Open, an address no app opens does nothing, and the same phone link clicked by
the agent asks the person again and the agent is told so); the agent hears of the HTTP authentication window as a
sign-in window and closes it; Chromium's windows belong to their tab (2026-10-27, "Chromium's windows belong to their
tab, and show over it", `compat.windowOwners` in `result.json`: it finds the tab of a sign-in window that appeared on a
background tab of another task, that window waits off screen because there is no panel, and the app is told to open that
task's panel at that tab. This task's agent neither hears of that window nor closes it, and meanwhile clicks, typing and
navigation work in its own tabs and the person's panel takes clicks too. The agent's clicks, typing and keys sent to the
tab under a window are not sent; the tools answer with a failure naming that window, the page's mousedown and keydown
counts are 0, and snapshot works. A window that appeared on this task's tab behind the panel waits, and when the panel
shows that tab it is placed over that panel, just in front of the panel's window, and the person's clicks do not reach
that page either. After a Yardlet window comes to the front, calling the click-handling path brings it to the front
again. When the tab is hidden the window hides too, and it comes back when the tab shows. The agents of two tasks each
close only their own windows); and when the person closes a tab that set "confirm before leaving", the "Leave site?"
sheet appears, Cancel keeps the tab, and Leave closes it in the host (host.log `browser closed tab=…`). QA does not open
other apps: a recorder (`RecordingExternalApps`) receives the addresses Yardlet would open, and only app names are read
from LaunchServices. Recorded only: permission states (`navigator.permissions.query`), full screen, file chooser modes
(`multiple`, `webkitdirectory`, the three File System Access functions), cookies and storage of cross-site frames (a
`SameSite=None` cookie in a `localhost` frame, `localStorage`, `hasStorageAccess`), HTTP basic authentication
(`/basic-auth`, user qa, password secret: the text of the host's window). Results are in `compat` in `result.json`; the
bars and the PDF, the warning page, the pop-up indicator and "Leave site?" are in `compat-*.png`. So that answers kept
in the profile, such as a camera block, do not carry over into the next run, each run uses a new QA home by using a
different parent for the output folder. The QA server also serves the same pages on a second port with a self-signed
certificate (HTTPS) (`openssl` creates the certificate in the output folder), and the page reports that address as
`window.qa.tls`. The QA bundle, QA home and output all go under `$TMPDIR` (the example above). If they are put in
`.build` inside a worktree under `~/Desktop`, macOS asks for Desktop folder access for every new QA bundle ID (on
2026-10-25 a permission window actually appeared), and meanwhile an `open()` of a file another process wrote did not get
past `sandboxd`'s check, so the QA app hung until the deadline (twice that day; the app's sample was in `open`). So the
QA app does not open files in the worktree. LaunchServices launches a bundle in `$TMPDIR` (`/var/folders/…`) as
`/private/var/folders/…`, so `qa-launch.sh` looks for both forms. Location, clipboard read, camera and microphone are
blocked on the bar before they reach macOS (Chromium does not ask macOS before the site is allowed; section 3,
"Permission requests"). Printing is not called, because the system print window would appear.

`--ui-fixture-browser-check-only=checkout` runs only card payment and card issuer verification (3-D Secure) (it is also
part of the full run, 2026-10-25). The QA server opens a second port as `localhost` (another site) to stand in for the
card issuer. It fills a card form (`/checkout`, Stripe's official test number 4242…, entered only on this loopback page)
and a shipping address form field by field, submits them and checks that the host is still there; that a device
information POST in a hidden iframe and authentication inside an iframe (`/checkout/frame`, the confirm button actually
clicked) go to the card issuer and come back by POST to the merchant and report through postMessage; that the whole page
POSTs to the card issuer and comes back (`/checkout/redirect`); that a card issuer window opened by a click answers
through `window.opener.postMessage` and closes itself (`/checkout/popup`); and that the host is still there through the
Payment Request of a wallet button (`/checkout/wallet`). A step that ended the host reopens it with "Try again", as the
person would, and continues with the next step. Each step is recorded in `checkout.json`. In the build before the fix,
submitting the card form ended the host with signal 11 (the stack in the crash report was the same as in the installed
app).


`--ui-fixture-browser-check-only=visual-context` runs only element picking and marking up attached images (2026-10-26,
`exerciseVisualContext`, QA path `/pick`). Checks: while picking, the edge pixels of the button under the mouse change
to the fill of Chromium's inspect mode (panel frame, `visual-context-hover.png`); a click attaches the element to that
task's composer draft (the selector finds only that element; HTML, styles, capture size) and ends the mode; clicks while
picking do not reach the page and clicks after it do; Esc and the button end it without attaching anything; typed
values, hidden fields, passwords and values the vault filled (QA reports them with `noteVaultValues`) are not in the
context text but replaced with "[saved value]", and the input fields in the capture have no text (the page frame does);
the markup editor, with its opening function (`ImageMarkupPresenter.open`) swapped so nothing appears on screen, draws
(`visual-context-markup-editor.png`), its marked-up copy takes the capture's place while the original stays, and the
next message numbers each capture. The composer chip is kept in the window image `visual-context-composer.png`, and the
text to send in `visual-context-draft-message.txt`.

`--ui-fixture-browser-check-only=isolation` runs only per-task profiles (`BrowserHostIsolationQA`,
[BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 6).

`--ui-fixture-browser-check-only=import` runs only importing sign-ins from another browser (`BrowserHostLoginImportQA`,
[BROWSER_SESSION_ISOLATION](BROWSER_SESSION_ISOLATION.md) section 10). In the QA home's Application Support it creates a
fake Whale folder (cookies encrypted with a test password), a fake Firefox folder (a plaintext `cookies.sqlite` left in
WAL), and a fake Chrome folder whose `Local State` cannot be read, and passes that password instead of the keychain. It
checks the panel's page menu item and sheet (`import-sheet.png`), the profile order and the browsers it could not read;
that the chosen site's cookies go once each into the default profile, the panel's task and a task created later, in the
shape that browser stored them (Firefox's converted to Chromium's shape); that the site's earlier cookies are deleted,
while other sites and Firefox container and partitioned cookies do not come in; and that no values appear in the app or
host logs.

`--ui-fixture-browser-check-only=vault` runs only the vault (`BrowserHostVaultQA`): it puts test items into the app's
vault (in memory in QA) and, through the Yardlet MCP broker, checks filling, codes, masking, refusal and turning off on
the `/vault/*` pages, the CDP virtual authenticator, registering and using a Yardlet passkey, and, in that task's panel,
the person's save bar, key button, right-click items and header mark, and keeps the panel screen as PNG. WebAuthn
requires a domain, so the vault pages open as `localhost`.

The passkey step of `run-check.sh` ("passkey requests observed"; only this with
`--ui-fixture-browser-check-only=passkey`) reads `getClientCapabilities()` on the `/passkey` page of `localhost` (a
secure context and a valid RP ID, with no passkeys), and makes the requests a site sends, one at a time: a conditional
request on the sign-in field (the field is clicked after the call), "Sign in with a passkey" (empty `allowCredentials`),
a sign-in that wants only this device, creation (no attachment), and creation on this device. Since 2026-10-27, after
those it makes the this-device-only sign-in twice more and moves the page to another site (`127.0.0.1`) and within the
same site (`localhost/passkey?moved`), to check that the window belongs to the panel tab and closes on navigation ("a
passkey dialog is its tab's and closes when the page moves", `passkeyMoves` in `result.json`). The DEBUG host writes its
own windows (title, whether key window, level) to `<output>/host-windows/windows.jsonl`, and a window's text, read
through its own accessibility, to `window-text-N.txt` (Views draws through the compositor, so PNGs come out empty.
Reading accessibility can turn on accessibility for all of Chromium, so at most three times per window). The requests
are withdrawn at the end with an AbortController. A conditional request that opens a window is a failure ("a passkey
autofill request with no passkey opens no window"). The two requests that go to the phone QR first make Chromium ask
macOS for Bluetooth, and macOS asks the person once, in its own window, the first time for each app identifier. So those
two are made only when the QA app's answer has been decided (`CBManager.authorization` is read without asking; on
2026-10-25 `com.zzunkie.yardlet.browserqa` was undecided, so they were skipped). Before, the first creation request of
the full run may have gone to the QR and brought up that window (while it was up, no dialog appeared, so the result
showed 0 windows; not confirmed). Since 2026-10-27 the step then attaches a CDP virtual authenticator to the panel's
tab with Chromium's own dialog on (`WebAuthn.enable` with `enableUI`), on this device's transport, holding a test
credential for `localhost` and one for another RP ID, as the stand-in for this Mac's Touch ID passkeys (a QA bundle has
no keychain group, so its Touch ID is off). It signs in with `allowCredentials` naming one credential on this device
(`/passkey` `getAllowed`, `window.qa.allow`): the `localhost` one with user verification passing and refused (the
fingerprint), one this Mac does not hold, and the other RP ID's. The list names only the `internal` transport, so
Chromium does not touch Bluetooth (`GetTransportsAllowedByRP`). Results are `devicePasskey` in `result.json`.

In the accessibility step, the app reads its own panel's accessibility tree directly, without any permission. It uses
the `/a11y` page (landmarks, headings, form controls, lists, tables, images, iframes, positioned buttons, buttons
further down) and the `/large` page (about 18,000 nodes). The tree is kept in `accessibility-dump.json`. The DEBUG host
saves the CEF accessibility values it receives as they are in `<output>/accessibility-raw/`. The unit tests' recorded
fixture (`Tests/NativeHarnessClientTests/Fixtures/cef-accessibility-qa-page.json`) came from here.
