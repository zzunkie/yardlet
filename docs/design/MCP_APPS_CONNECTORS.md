# MCP Apps for Yardlet's connectors (stage 1)

Design record, 2026-11-11. The current contract, once built, is in [CONNECTORS](../CONNECTORS.md).

## What this decides

MCP Apps (extension `io.modelcontextprotocol/ui`, stable spec 2026-01-26) lets an MCP tool name an HTML view
(`_meta.ui.resourceUri`, a `ui://` URI). The host reads the HTML with `resources/read`, draws it in an isolated
frame inside the conversation, and talks to it with JSON-RPC over `postMessage`. The Claude app draws these views;
Yardlet draws none, and its connector client passes on only a result's `content`, `structuredContent` and `isError`.
The person's saved connectors already list six such tools: Slack `slack_send_message_draft`; GitHub
`create_pull_request`, `update_pull_request`, `issue_write`, `get_me`, and `ui_get`, which is for views only
(`visibility: ["app"]`) and today reaches the model anyway.

Stage 1 covers connectors where Yardlet itself is the MCP client (remote servers such as Slack, GitHub, Linear and
Notion, and program connectors). It draws their views the same way in Claude Code, Codex and Antigravity tasks.
Servers a harness loads itself, Claude Code's own MCP Apps host mode, and Codex or Antigravity internals are out of
scope.

## What the spec binds a host to

- Tools whose `visibility` lacks `"model"` must not reach the model; a view may call only tools whose `visibility`
  has `"app"` (the default is both), and only on the server that gave it.
- The view is untrusted. It runs in a frame whose origin differs from the host's, with `allow-scripts` and
  `allow-same-origin`, under a Content Security Policy built from `_meta.ui.csp` of the resource: `default-src
  'none'`, scripts and styles inline or from `resourceDomains`, network only to `connectDomains`, frames only from
  `frameDomains`, `object-src 'none'`, `base-uri 'self'` unless `baseUriDomains`. A host may restrict more, never
  less.
- Lifecycle: the view sends `ui/initialize` (the host answers with its capabilities and `hostContext`: theme, style
  variables, display mode, size limits, locale, time zone), then `ui/notifications/initialized`. The host must not
  send anything before that, then sends `ui/notifications/tool-input` (once) and `ui/notifications/tool-result`
  (or `tool-cancelled`), and `ui/resource-teardown` before it removes the view.
- The view may send `tools/call`, `resources/read`, `notifications/message`, `ping`, `ui/open-link`, `ui/message`,
  `ui/update-model-context`, `ui/request-display-mode` and `ui/notifications/size-changed`. The host may refuse or
  ask the person about any of them.
- A host that draws views advertises the extension in `initialize` (`capabilities.extensions`). Servers should
  check it before offering UI tools.

## Design

### 1. Tool lists

- `ConnectorCenter.connectorTools` leaves out every tool whose `_meta.ui.visibility` lacks `"model"` (GitHub's
  `ui_get`). A model call to such a name is answered as an unknown tool. `ConnectorToolLabels` still knows it, so
  a view can call it.
- `exposedTool` removes `_meta.ui` (and the deprecated `_meta["ui/resourceUri"]`) from the copy a harness gets:
  the Yardlet MCP server has no resources to read, and only the app draws views. Each harness's list changes once
  (`tools/list_changed`).
- `ConnectorToolLabels.Label` gains `appView` (the resource URI) and `visibility`, read from the tool list kept in
  `connectors.json`, so the conversation can tell a row has a view without asking a server.

### 2. Reading the view

- `MCPHTTPClient.readResource(uri:)` sends `resources/read`; `ConnectorSession.readResource` adds the sign-in the
  same way `callTool` does. Program connectors get the same over stdio (`MCPStdioClient`).
- `ConnectorCenter.appView(forTool:)` reads the HTML of the connector that owns the tool. It accepts only a `ui://`
  URI that the tool itself names, a content item of `text/html` (with or without `;profile=mcp-app`) in `text` or
  base64 `blob`, and at most 5 MB. `_meta.ui` comes from the content item. A view read once is kept in memory for
  the app's run (eight at most, least recently used out), keyed by connector and URI.
- Whether Yardlet advertises the extension in `initialize` is the open decision below. Stage 1 is built so that
  either answer is one line.

### 3. Which result a view shows

- The view needs the call's whole `CallToolResult` (`content`, `structuredContent`, `_meta`), and harnesses keep
  less: Claude Code and Antigravity keep text, Codex keeps `content` and `structuredContent`.
- So when a call to a tool with a view returns, `ConnectorCenter` keeps the result in memory (`ConnectorAppCalls`)
  under the task, Yardlet's tool name and the call's arguments written as sorted, compact JSON, the newest first.
  At most 20 per task and 200 in all, none over 1 MB; nothing is written to disk. The result's own `_meta` is not
  kept (the views seen so far read `content` and `structuredContent` only).
- A conversation row finds its result by the same key, read from what every harness records: the tool name
  (Claude Code `mcp__yardlet__<name>`, Codex server `yardlet` and tool `<name>`, Antigravity `mcp_yardlet_<name>`
  or `mcp_yardlet_<8 hex>_<name>`) and the arguments the row shows.
- A row with no kept result (a conversation from before Yardlet last started, or a call made through another copy
  of the app) builds one from what its harness kept, for a read-only tool (`readOnlyHint: true`) only: Codex's
  result as it is, or the row's text as one text item. GitHub's `get_me` view reads the text; a view that needs
  more shows its own error. A tool that changes something shows its view only with the whole result: GitHub's
  write views draw their form when they cannot read the result as a finished one (`completedToolResult` in its
  `ui/src/lib/toolResult.ts`), and that form would make the pull request or issue a second time.
- Two calls with the same arguments in one task both show the newer result.

### 4. In the conversation

- A completed connector call whose tool has a view stays a tool row (`ConversationTool.view`), so the Windows app,
  the phone remote and the remote projections draw its text as today. It does not join a group of calls, and a
  folded turn keeps it in view, as it keeps a suggested task, so the view is not hidden inside "Ran 5 tools". The
  row draws its usual line (connector icon, "GitHub: create pull request") open, with the view as its detail;
  folding the line hides the view, as folding any line hides its detail. Input and output stay in "Copy item
  details".
- A running call is still a tool row; it turns into the view when it completes. A failed call stays a tool row.
- The view's frame is as wide as the conversation's text column and as tall as the view reports
  (`size-changed`), up to 600 points, after which it scrolls inside. `prefersBorder` true or absent draws a
  1-point hairline and corner radius around it; false draws none.

### 5. Hosting the view

- One `WKWebView` per live view, in its own non-persistent data store, so it shares no cookies or storage with
  Yardlet's browser, the person's other views or other tasks. It has no file URLs, no Yardlet scheme handlers but
  its own, and no script message handler in the page's world.
- Yardlet serves two documents from a custom scheme (`yardlet-mcp-view://`) through a `WKURLSchemeHandler`:
  - the outer page, at a random host per view, holds one `<iframe sandbox="allow-scripts allow-same-origin">`;
  - the view's HTML, at a second random host, sent with the CSP built from `_meta.ui.csp` as an HTTP header (not a
    `<meta>` tag the view could precede), plus `object-src 'none'` and `frame-ancestors` the outer host.
  The two hosts are two origins, so the view cannot reach the outer page's document, and neither is Yardlet.
- The bridge is a script in an isolated content world (`WKContentWorld`) of the outer page, main frame only. It
  takes `message` events whose source is the view's frame and passes them to a message handler that exists only
  in that world; the app answers by posting into the view's frame from the same world. The view's own scripts
  cannot see the handler.
- Policy: the outer page loads once; every other navigation of either frame is cancelled; `window.open` makes
  nothing; downloads are cancelled; camera, microphone and location are refused (stage 1 grants no
  `permissions`); nothing the view loads may use another scheme than `https`, `data` and its own.
- A web process that ends (crash or memory) shows the row's text with "Show view again".

### 6. The bridge

| From the view | Yardlet's answer |
|---|---|
| `ui/initialize` | `protocolVersion` 2026-01-26, `hostInfo` Yardlet and its version, `hostCapabilities` `openLinks`, `serverTools`, `serverResources`, `logging`; `hostContext` with `toolInfo` (the tool as the server listed it), `theme`, style variables for colors, fonts and radii as `light-dark()` pairs, `displayMode` `inline`, `availableDisplayModes` `["inline"]`, `containerDimensions` `{maxWidth, maxHeight: 600}`, `locale`, `timeZone`, `platform` `desktop` |
| `ui/notifications/initialized` | Yardlet then sends `tool-input` with the arguments and `tool-result` with the result |
| `tools/call` | Section 7 |
| `resources/read` | Only `ui://` URIs of the same connector, through the same session |
| `ui/open-link` | `http` and `https` only, opened as a link in the conversation opens (the task's browser panel), at most one a second; others refused |
| `ui/notifications/size-changed` | The frame's height (and nothing else) follows, at most once per display frame |
| `notifications/message`, `ping` | Accepted; nothing of the message is logged |
| `ui/message`, `ui/update-model-context` | Refused with -32000 in stage 1: Yardlet has no route yet that adds a view's words to the task without starting a turn the person did not ask for |
| `ui/request-display-mode` | Answers `inline` |
| Anything else, malformed JSON-RPC, or over 1 MB | An error for requests; dropped for notifications |

Yardlet sends `ui/notifications/host-context-changed` when the theme changes, and `ui/resource-teardown` (waiting
up to one second) before it removes a view.

### 7. Calls a view makes

A view's `tools/call` names a tool by its server's own name. Yardlet runs it only if all hold:

1. The tool belongs to the connector that served the view, and its `visibility` includes `"app"`.
2. It goes through `ConnectorCenter.callConnectorTool` under the task's Yardlet name, so it gets every check a
   model's call gets: the connector is on in this task and connected, a shared tool names an account the task has,
   Yardlet's own servers check the schema, one time limit, and the rule that a change is never sent twice.
3. A tool not marked `readOnlyHint: true` asks the person first, on the task's request card that Yardlet's own
   session tools use (`AppModel.askPerson`), in every permission mode: "Allow the GitHub view to create pull
   request?" with the arguments as the detail. Declining answers the view with an error. A click inside the view is
   not taken as consent, since the view's script can call without one, and the task's mode is a choice about the
   agent, not about a server's page. A view drawn again (after it was off screen, or after Yardlet restarted) asks
   again for any write it makes.
4. At most four calls of one view at a time; more get an error. A read a view makes when it is drawn again goes to
   the server again, as the view asks.

No call a view makes reaches the harness or the model, and none bypasses a check the model's calls get.

### 8. Cost

- Projection: deciding that a row has a view is a dictionary lookup in `ConnectorToolLabels` for connector rows
  only; matching the kept result encodes that row's arguments once. Nothing else in the conversation changes.
- A view's web view is made only when its item is on screen, never when the item is only projected. The row's AppKit
  container tells this from the conversation's scroll view, since each turn is drawn in a hosting view of its own
  (`ConversationTurnHost`) that a SwiftUI scroll position does not reach. At most four live at once across the app; past that, the least recently seen one that is off
  screen is torn down and keeps its last height until it is seen again.
- The item compares equal on its item and phase, so a turn's streaming does not redraw it, and no event reaches a
  live view except the ones in section 6.
- Checked with a conversation of 3,000 items holding 50 view items: the number of web views made, the item's
  redraws during a streamed turn, and the projection time.

### 9. Fallback

The row stays today's tool row, with its text, whenever: the tool has no view, the call failed, the connector is gone
or not connected, `resources/read` fails or answers something section 2 refuses, the web process ends, or the view
does not send `ui/initialize` within ten seconds. The Windows app and the phone remote show the text row.

### 10. Removal and settings

No settings switch: each view folds with its line, a connector turned off in the task offers no calls, and removing
a connector removes its views. Everything is in memory: kept results, read views, web views and their
data stores. Removing the feature leaves nothing in the person's home. The tool list each harness sees changes once
when it ships (section 1) and once again if it is removed.

### 11. Verification

- Unit tests with a local fake MCP server that serves a tool with a view, an app-only tool, and `resources/read`:
  the list leaves out the app-only tool, the read checks, the kept result and its matching per harness, a view's
  call to a model-only tool or another server's tool refused, a write asking, the read path through sign-in renewal.
- A bridge test in an off-screen `WKWebView` with a fake view: handshake order, CSP (a fetch to an undeclared host
  fails), navigation and `window.open` refused, the handler unreachable from the view.
- Rendered evidence in light and dark: a fake view, and the real GitHub `get_me` view and result read without writing.

## Decision for the person

**Should Yardlet tell connector servers that it draws views?**

- **A. Tell them** (the standard; the Claude app does). GitHub then turns `create_pull_request`,
  `update_pull_request` and `issue_write` into a form: the model's call creates nothing and answers that a form
  waits for the person, and the pull request or issue is made when the person submits the view (that call asks
  first, section 7, unless the task runs without asking). A scheduled task or subagent that opens pull requests
  through the GitHub connector would stop there. What Slack's draft tool does differently is not public.
- **B. Do not tell them** (recommended for stage 1). Every tool behaves as today; views show the result. GitHub's
  write views show the pull request or issue just made when they get a finished result (`pr-write/App.tsx`: "When
  the server executed up-front instead of deferring to this form … the host still renders this View and delivers
  the created PR via tool-result"), and `get_me` the profile card. B departs from the spec, which has a host that
  draws views say so; it works because GitHub keeps the view data for a client that says nothing either way
  (`pkg/inventory/registry.go`, `shouldStripMCPAppsMetadata`, strips it only for a client known not to draw views)
  and serves the views to any client (`pkg/github/server.go`). Its list read on 2026-11-11 had all six tools. If a
  server stops sending view data to such clients, its views fall back to text without any error.
- Sources for A: `pkg/github/ui_capability.go` (`shouldDeferToForm`) in GitHub's MCP server, read on 2026-11-11.
  Slack's server is not public.
- In between: telling only some connectors, or only for tasks a person watches. Yardlet has one MCP session per
  connector, shared by every task, and the capability is said once per session, so either needs a session per
  task or per kind of task. Not in stage 1.

B is recommended because it changes no tool's behavior for running and scheduled tasks while still drawing every view
these servers send today. A needs more than the one line that says it: after a person submits a form, the model
learns nothing of it until Yardlet passes `ui/update-model-context` or `ui/message` to the task, which stage 1
refuses; and a form being filled in is lost when its view is torn down off screen. Those come with A, in a later
stage.
