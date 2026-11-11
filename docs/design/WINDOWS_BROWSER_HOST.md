# Windows browser host design (WebView2)

A design that is not built yet. The Windows app has no browser host
([PLATFORM_PORTABILITY](../PLATFORM_PORTABILITY.md), "The Windows app"); this is the design to follow when it gets one,
and nothing here has been run on Windows. It rests on the product decision (CEF on macOS, WebView2 on Windows). How the
browser works on macOS today is in [BROWSER_HOST](../BROWSER_HOST.md); where this design describes the macOS side, that
document is right. API names follow Microsoft's
[WebView2 documentation](https://learn.microsoft.com/microsoft-edge/webview2/) and are to be checked again against the
SDK version at implementation time.

## 1. Principles

- The engine's browser host protocol (`Sources/NativeHarnessClient/BrowserHost/BrowserHostProtocol.swift`), the CDP
  client, the agent browser tools and the Yardlet MCP server use the same code as on macOS. What Windows adds is one
  host implementation that runs the protocol on WebView2, and one CDP transport adapter.
- WebView2 is a Chromium runtime the operating system shares (Evergreen), so the app does not grow, and the runtime
  starts the browser, renderer and GPU processes on its own. So unlike macOS, there is no need to build a host process
  ourselves.
- Windowed hosting (passing the panel's HWND as the parent to `CreateCoreWebView2Controller`) is the default. In this
  mode WebView2 handles input, the Korean IME, the cursor, `<select>` popups, the context menu and accessibility (UI
  Automation) on its own. The input forwarding and accessibility bridge built by hand on macOS are not needed on
  Windows.
- The Windows app's screens are WinUI 3, and its bindings already project WebView2's types (`Windows/Bindings`). The
  design needs only that the panel can give one HWND.

## 2. Protocol mapping

### Commands

| Protocol command | WebView2 |
|---|---|
| `open(tab, url, viewport)` | In the one environment per app (`CreateCoreWebView2EnvironmentWithOptions`, with a user data folder given), `CreateCoreWebView2Controller(panel HWND)` per tab, then `Navigate(url)` |
| `resize` | `ICoreWebView2Controller::put_Bounds`, and the scale with `put_RasterizationScale` |
| `navigate` | `ICoreWebView2::Navigate` |
| `navigation(back/forward/reload/stop)` | `GoBack`, `GoForward`, `Reload`, `Stop` |
| `focus` | `ICoreWebView2Controller::MoveFocus` |
| `visibility` | `put_IsVisible`. When the tab is hidden for long, `TrySuspend` can pause the renderer |
| `devTools(message)` | `CallDevToolsProtocolMethod(method, paramsJSON)`. Event subscription is `GetDevToolsProtocolEventReceiver(eventName)` |
| `close(tab)` | `ICoreWebView2Controller::Close` |
| `shutdown` | Close every controller and release the environment |
| `mouse`, `wheel`, `key`, `composition`, `edit`, `contextMenuResult` | Not used in windowed hosting (WebView2 receives the input directly). If composition (Visual) hosting is chosen, only `mouse` and `wheel` carry over, to `ICoreWebView2CompositionController::SendMouseInput` |

### Events

| Protocol event | WebView2 |
|---|---|
| `ready` | The environment is created. `engine` gets the runtime's `BrowserVersionString`, and `acceleratedPaint` has no meaning, so it is `false` |
| `opened` | The controller is created |
| `address` | `get_Source` after `SourceChanged` |
| `title` | `DocumentTitleChanged` |
| `loading` | `NavigationStarting` and `NavigationCompleted`, and `CanGoBack` and `CanGoForward` on `HistoryChanged` |
| `loadEnd`, `loadError` | `IsSuccess`, `WebErrorStatus` and `HttpStatusCode` of `NavigationCompleted` |
| `console` | CDP `Runtime.consoleAPICalled` received through the DevTools event receiver (the same path as on macOS) |
| `popupBlocked` or a new window | Handle `NewWindowRequested` with the macOS policy ([BROWSER_HOST](../BROWSER_HOST.md) section 3, "New windows"): a permitted new window becomes a tab of the task |
| `terminated`, `failed` | `ProcessFailed`, and the environment's `BrowserProcessExited` |
| `frame`, `popup`, `cursor`, `contextMenu`, `compositionBounds` | Do not occur in windowed hosting |

JS dialogs, file choosing and downloads, which the macOS host has, map to `ScriptDialogOpening` (with the
default dialog turned off, shown as a Yardlet sheet), the WebView2 default file chooser, and `DownloadStarting`
respectively.

## 3. Lifetime and memory

- The host lifetime rules are the same as on macOS ([BROWSER_HOST](../BROWSER_HOST.md) section 3, "Host lifetime"): a
  task's tabs stay until the task is archived or deleted, and a tab that is not visible is hidden. When the last
  controller is closed and the environment is released, the runtime ends the browser process, and
  `BrowserProcessExited` confirms that the memory was returned.
- The default profile is `%LOCALAPPDATA%\Yardlet\Browser\Default`. WebView2 handles cookie encryption with DPAPI, so
  no compromise like the mock keychain on macOS is needed.

## 4. Agent tools and the MCP server

- The engine's CDP client changes only its transport. macOS sends CDP messages over the host IPC, and Windows sends them
  with `CallDevToolsProtocolMethod` and the event receiver. The handling of tools (`browser_snapshot` and the others)
  and references (`@e3`) stays the same.
- The Yardlet MCP server is an executable that uses only Foundation, so it is rebuilt for Windows. The Unix domain
  socket of the IPC can be used as AF_UNIX from Windows 10 on, and folder ACLs limit access to the user.
- The harness injection paths (Claude `--mcp-config`, Codex `thread/start` settings, ACP `session/new`) do not depend on
  the platform.

## 5. Distribution

- Windows 11 and current Windows 10 have the Evergreen WebView2 runtime by default. At app start Yardlet checks with
  `GetAvailableCoreWebView2BrowserVersionString`, and when it is missing, shows Microsoft's official install
  instructions. Bundling a fixed-version runtime in the app is not used, because of its size.

## 6. Open decisions and prerequisites

- How a WinUI 3 panel gives the controller its HWND, or whether the panel hosts WinUI's own WebView2 control instead.
- Profiles of a task's own ([BROWSER_SESSION_ISOLATION](../BROWSER_SESSION_ISOLATION.md)): which WebView2 profile or
  user data folder a task that takes its own profile gets.
- Checking the behavior of the mapping tables above on a real Windows device.
