# Connectors

This document is the current contract for Yardlet connectors. The Yardlet MCP server that puts connector tools into
harnesses, and the injection paths, are in [AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md). Below, "the X section" names a
section of this document by its title.

## 1. Overview

- A connector is a remote MCP server (Streamable HTTP) that an outside service runs. Yardlet signs in once, keeps the
  credentials in Keychain, and offers that server's tools to Claude Code, Codex and ACP harnesses through the Yardlet
  MCP server (`yardlet`). The exceptions are Gmail, Google Calendar, Google Drive, Google Analytics and Google Ads,
  which are servers Yardlet runs inside the app. They sign in once per Google account and call Google's public REST APIs
  (the "Google" section). Outlook Mail, Outlook Calendar, OneDrive and Microsoft Teams are servers inside the app as
  well: they sign in once per Microsoft account and call Microsoft Graph (the "Microsoft 365" section). The Apple
  connectors (App Store Connect, the Mac's calendars, reminders and contacts, and Xcode) are also servers inside
  the app. App Store Connect calls Apple's REST API with the person's API key, the three Mac connectors use the Mac's
  data once macOS allows it, and Xcode goes through Xcode's `mcpbridge` (the "Apple" section). A connector can also be
  a program Yardlet runs on this Mac (stdio), from an MCP registry or another app's settings, once the person has seen
  what it runs and said yes (the "Programs on this Mac" section).
- Besides its own directory, Add connector lists the public MCP registries' servers and searches them (the
  "Registries" section).
- **Every harness and account gets the same connectors.** Claude Code keeps claude.ai connectors and `claude mcp add`
  entries separately for each config folder (`CLAUDE_CONFIG_DIR`), so with several Claude accounts each account has
  different connections. Yardlet adds its connectors per process (Claude `--mcp-config`, the Codex thread `config`, ACP
  `mcpServers`), so a task in any harness and account gets the same connectors. Nothing is written to the user's
  settings files, so removing Yardlet leaves no trace. Antigravity tasks do not get them.
- Tokens never leave the Yardlet process. The harness calls through `yardlet-mcp`, and Yardlet is the one that sends
  requests to the remote server. Tokens are not written to harness settings files either.
- Connecting and managing happen in Settings → Connectors; turning a connector on or off per task and reconnecting
  happen in the composer's "+" → "Connectors" (the "UI" section).

## 2. Connection types

| Type | When | Behavior |
|---|---|---|
| OAuth (dynamic registration) | The server asks for sign-in with a 401 and supports dynamic client registration | The steps below |
| OAuth (your own client) | No dynamic registration (Slack, Zoom, a GitHub OAuth app the user registered) | The steps below, with the user's client ID (and secret) and a fixed redirect in place of step 4 |
| GitHub device code | GitHub, when the build has the client ID of Yardlet's GitHub OAuth app | The "GitHub sign-in" section |
| Access token | Servers without dynamic registration (GitHub personal access tokens and others) | Sends the pasted value as `Authorization: Bearer` |
| Key in a header | A registry server that names its own header for the key (`x-api-key`) | Sends the pasted value as is in that header (`tokenHeader`), not in `Authorization` |
| Key in the address | Servers that take the key as a query (Browserbase `browserbaseApiKey`) | Adds it to the address on each request. It is not in the saved address or headers |
| No authentication | The server answers without a 401 | Connects as is |
| Google account | Gmail, Google Calendar, Google Drive, Google Analytics and Google Ads | The "Google" section |
| Microsoft account | Outlook Mail, Outlook Calendar, OneDrive and Microsoft Teams | The "Microsoft 365" section |
| App Store Connect API key | App Store Connect | The `.p8` key file, the key ID and (for a team key) the issuer ID. The "Apple" section |
| macOS permission | Apple Calendar, Apple Reminders and Apple Contacts | macOS asks once when it is turned on. The "Apple" section |
| App on this Mac | Xcode | No sign-in. Xcode's `mcpbridge` provides the tools. The "Apple" section |
| Program on this Mac | A registry package (`npx`, `uvx`, `docker run`) or a program another app's settings start | Runs after the person confirms what runs; its arguments and environment values are in Keychain. The "Programs on this Mac" section |

OAuth steps (the MCP authorization spec):

1. Send `initialize` without a token and get a 401. Read `resource_metadata` and `scope` from
   `WWW-Authenticate: Bearer`. A connector with its own client signs in first, without waiting for a 401. Some servers
   answer `initialize` and `tools/list` for anyone and refuse only `tools/call`, so otherwise the connector would show
   "Connected" and then fail on a call.
2. Protected resource metadata (RFC 9728): the address the header points to, else
   `/.well-known/oauth-protected-resource<path>`, then the root. For a server without the metadata (Atlassian), the
   server's origin is taken as the authorization server (the fallback in the 2025-03-26 spec).
3. Authorization server metadata (RFC 8414, OpenID): with an issuer path, the two path-inserted forms and OpenID after
   the path; without one, the two root forms. A trailing `/` on the issuer (for example `https://accounts.google.com/`)
   is not a path.
4. Client:
   - Dynamic client registration (RFC 7591): every sign-in registers a new redirect URI, `/callback` on a random port of
     `127.0.0.1`. If the server accepts `none`, it is a public client; otherwise it uses whichever of
     `client_secret_post` and `client_secret_basic` the server accepts.
   - Your own client: no registration. The redirect URI is the fixed `http://127.0.0.1:47823/callback` (the value the
     user enters in the service's app settings; Slack apps and OAuth clients of the web application type must match it
     exactly, port included). Without a secret it is a PKCE public client (`none`, Slack's PKCE app). With one, the
     secret is sent in the form when the server accepts `client_secret_post` or does not say which method it takes
     (GitHub), and as Basic when it accepts only `client_secret_basic`.
5. Open the authorization page in the default browser with authorization code + PKCE S256, `state`, `resource` (RFC
   8707), `scope` (the connector's scope, else the header's value, else the metadata's `scopes_supported`) and the
   directory entry's extra authorization parameters. The user's existing browser sign-in is used as is, and Yardlet
   never sees the password.
6. When the loopback listener gets the first `GET /callback`, it returns a "Connected to Yardlet" page and brings
   Yardlet to the front. It ends if nothing arrives within 5 minutes or the user cancels. Cancel on the authorization
   page (`error=access_denied`) is the same as "Cancel" in Yardlet and is not kept as an error
   (`ConnectorOAuthError.declined`). A different `state` is refused.
7. A token request gets the access and refresh tokens, which are stored in Keychain, and then `initialize` and
   `tools/list` are sent again.

Directory entries that need your own client or a token (Slack, Browserbase and GitHub in a build without device code
sign-in) do not start connecting without one; they show "Connect with an OAuth client of your own or an access token."
(no request is sent). Disconnect removes only the token and keeps your own client, so connecting again signs in right
away. Remove deletes everything.

Reconnect (`ConnectorCenter.reconnect`) signs in anew even when the saved OAuth sign-in still works, and keeps using the
saved token until it stores the new one. Where to sign in comes from asking the server once without a token. So a
cancelled reconnect does not change the connection, the tools or the row's place in the settings list. A reconnect that
fails for another reason (a time-out, a different account) and a tool reload also leave the connection and tools as they
are; that row keeps "Connected" and its place and shows the reason in one line (the "UI" section). Only the user can
change a pasted token, so reconnecting leaves it as it is.

Token refresh: when the token expires within 1 minute, it is refreshed before the call. When the server returns 401, it
is refreshed once and the request is sent again. Only one refresh runs at a time, so servers that rotate refresh tokens
do not get tangled (`ConnectorSession`).

- Before a refresh, the Keychain item is read again. If another copy of Yardlet (same bundle ID) has already refreshed
  and stored a token that expires at the same time or later, that token is used without a request. A refresh result is
  stored only over the value it was made from (it is not stored if a newer value arrived in the meantime or the
  connector was removed).
- On a refusal (`invalid_grant`, or another 4xx such as an unknown client), Keychain is read again at once and once more
  1 second later. If another copy has just changed the token, that one is used; only if not does the call become a tool
  error saying to sign in again. The connector becomes "Needs sign-in".
- Temporary failures (transport errors such as no network or a time-out, 5xx, 408, 429, `temporarily_unavailable` and
  `server_error`, a 2xx without a token) are retried after 1 and 2 seconds (three tries in all). If it still fails, only
  that call becomes a tool error saying the sign-in could not be renewed just now, and the connector stays connected.
  The next call refreshes again. This keeps a temporary error right after sleep from turning into "Needs sign-in".

MCP session: later requests carry the `Mcp-Session-Id` the server gave and the negotiated `MCP-Protocol-Version`. If the
server forgets the session (404), Yardlet initializes once more. A reply is JSON or a short event stream; notifications
inside the stream are skipped, and the response with the same `id` is used.

## 3. Directory

The directory (`ConnectorPreset.all`) is a list of remote MCP servers that anyone can use. Each entry sets its sign-in
type, confirmed with unauthenticated public requests (`initialize` without a token, protected resource metadata,
authorization server metadata) and the service's public docs. It is not confirmed by signing in, by a dynamic
registration POST or by a token request. Even when a registration endpoint exists, this method cannot tell whether the
service accepts only some clients, so only services confirmed through public docs were left out. If a service refuses
registration, the connection error shows the reason the service gave.

| Sign-in | Services |
|---|---|
| Dynamic registration OAuth | Linear, Notion, Atlassian, Sentry, Asana, ClickUp, monday.com, Todoist, Airtable, Miro, Dropbox, Intercom, Zapier, Pipedream, Composio, Make, Granola, Fireflies, Gamma, Basecamp, Teamwork, Lucid, PandaDoc, Fathom, DeepL, Mobbin, Apollo.io (read-only), Attio, Customer.io, Klaviyo, MailerLite, Ahrefs, Semrush, Similarweb, Amplitude, Mixpanel, GitLab, Supabase, Neon, Prisma Postgres, Netlify, Cloudflare, PostHog, Semgrep, Postman, Jam, CircleCI, BrowserStack, BugSnag, Swagger, Zephyr, Grafana, Honeycomb, Axiom, Statsig, Port, Aiven, Upstash, Algolia, Contentful, Sanity, WorkOS, Apify, Mapbox, Stripe, PayPal, Square, Mercury (read-only), Webflow, Wix, Ramp (read-only), Brex (read-only), Paddle, Beancount.io, Hostinger, Tavily |
| No authentication | Exa, Hugging Face, Context7, DeepWiki, OpenAI Docs, Microsoft Learn, AWS Knowledge, Cloudflare Docs, Twilio Docs, the Figma desktop app server (`http://127.0.0.1:3845/mcp`, turned on in Dev Mode). Exa, Hugging Face and Context7 allow more after a sign-in, but Yardlet does not ask for one |
| Your own OAuth app | Slack (the "Slack" section), Zoom Meetings, Zoom Team Chat, Zoom Docs |
| Google account | Gmail, Google Calendar, Google Drive, Google Analytics, Google Ads (the "Google" section) |
| Microsoft account | Outlook Mail, Outlook Calendar, OneDrive, Microsoft Teams (the "Microsoft 365" section) |
| Apple | App Store Connect (API key), Apple Calendar, Apple Reminders and Apple Contacts (macOS permission), Xcode (`mcpbridge` on this Mac) (the "Apple" section) |
| GitHub | GitHub (`https://api.githubcopilot.com/mcp/`): device code sign-in (the "GitHub sign-in" section), a personal access token or your own OAuth app |
| Key in the address | Browserbase (`https://mcp.browserbase.com/mcp`, key in Keychain) |

- Order: widely used services (Linear, Notion, Slack, the five Google services, the four Microsoft services, the three
  Mac services, GitHub,
  Browserbase, Atlassian, Sentry) → work and planning → sales, marketing and product analytics → development and
  operations (Xcode and App Store Connect first) → payments and sites → Figma desktop → search and docs. Within a group,
  services added later come after the earlier ones. An entry's symbol (SF Symbol) is used before the service icon
  arrives and when it cannot be fetched (the "Icons" section). The directory search narrows the list by name.
- Xcode appears in the list only when this Mac has `mcpbridge`, and App Store Connect only when the build can sign
  tokens (`ConnectorCenter.isAvailable`).
- Asana uses `/mcp`, which supports dynamic registration. The new address (`/v2/mcp`) needs an app registration.
- Mercury (`https://mcp.mercury.com/mcp`) is read-only. The directory entry's scope is `read offline_access`, so even
  when the server also lists write scopes, Yardlet asks only for reading and a refresh token
  (docs.mercury.com/docs/connecting-mercury-mcp). The tools for payment requests, transfer requests between accounts,
  creating and editing categories, and transaction notes lack that scope and do not appear in the list. "Read-only"
  shows under the Mercury line in the Add connector sheet. Sign-in follows the OAuth steps in the "Connection types"
  section as they are. Mercury accepts public client dynamic registration and PKCE `S256`, and keeps its protected
  resource metadata only at the root (`/.well-known/oauth-protected-resource`).
- Pipedream (`https://mcp.pipedream.net/v2`), Composio (`https://connect.composio.dev/mcp`) and Make
  (`https://mcp.make.com/v2`) reach many apps through one sign-in, as Zapier does. Each runs its own server and answered an
  unauthenticated GET on 2026-10-27 with 401 and OAuth metadata that has a registration endpoint and PKCE `S256`.
  Pipedream keeps its protected resource metadata only at the root; Make takes `client_secret_post` alone, which
  dynamic registration already handles. IFTTT (`https://ifttt.com/mcp`, GET 200) and Activepieces
  (`https://cloud.activepieces.com/mcp`, GET 405) also publish registration metadata, but a GET could not show whether they
  ask for a sign-in before listing tools, so they are left to a registry search until a connection is tried. Merge Agent
  Handler's docs sign in with Merge's own command-line tool first; n8n, Klavis, Arcade and Gumloop give each person or
  workspace its own address, so they are added by URL.
- Zoom (`https://mcp.zoom.us/mcp/{meeting,chat,canvas}/streamable`, developers.zoom.us/docs/mcp/servers) has one server
  per product. Its servers answer an unauthenticated `initialize` with 401 and protected resource metadata that names
  `https://zoom.us` as the authorization server, which has no registration endpoint and takes the secret only as Basic
  (`client_secret_basic`) with PKCE `S256` (2026-10-27). So each product signs in with a Zoom app of the person's own (a
  General app, user-managed) and the fixed loopback redirect, which Zoom accepts for native clients. The three entries
  ask only for the read scopes of their server's `scopes_supported`: meetings, their assets and recordings; Team Chat
  messages, channels, contacts and files; and Docs files, exports and comments (`canvas:write:file_search` searches and
  writes nothing). The Zoom page in Add connector takes the client once, adds the products picked, and signs each in
  in turn. A product the account's plan lacks still connects, and its tools answer with Zoom's reason.
- Forty services were added on 2026-10-29 after the same unauthenticated checks: each server answered `initialize`
  without a token with 401 (Teamwork answers it and refuses a GET with 401), and its protected resource metadata,
  authorization server metadata, registration endpoint and PKCE `S256` were all public. No registration POST, sign-in
  or tool call was made, so whether each service accepts Yardlet's registration and loopback redirect is learned on the
  first connection. They are Basecamp, Teamwork, Lucid, PandaDoc, Fathom, DeepL and Mobbin (work and planning);
  Apollo.io, Attio, Customer.io, Klaviyo, MailerLite, Ahrefs, Semrush, Similarweb, Amplitude and Mixpanel (sales,
  marketing and product analytics); CircleCI, BrowserStack, BugSnag, Swagger, Zephyr, Grafana, Honeycomb, Axiom,
  Statsig, Port, Aiven, Upstash, Algolia, Contentful, Sanity, WorkOS, Apify and Mapbox (development and operations); and
  Ramp, Brex, Paddle, Beancount.io and Hostinger (payments and sites).
  - Scopes: each asks for what its server lists (step 5 of the OAuth steps), except three whose lists reach payments,
    cards, bank accounts, purchases or sending. For those, Yardlet's product scope is reading, and the directory entry
    fixes a few read scopes picked from the server's own `scopes_supported`: Ramp `transactions:read business:read
    cards:read`; Brex `openid offline_access users.readonly expenses.card.readonly accounts.cash.readonly`; Apollo.io
    `read_user_profile app_scopes people_match organizations_enrich contacts_search`. These sets are a choice made from
    public metadata, not one confirmed by a sign-in: tools that need another scope do not appear or answer with the
    service's reason. "Read-only" shows under these lines in the Add connector sheet, as for Mercury.
  - Some servers list write scopes that the person grants or refuses on the service's own sign-in page: Customer.io
    sends messages only with `write:live`, which an account admin must also allow (docs.customer.io/ai/mcp/get-started),
    and PandaDoc asks what the assistant may access. Brex's MCP needs an account admin to turn on its early access first.
  - PandaDoc's authorization server takes only `client_secret_post` and `client_secret_basic`, which dynamic
    registration already handles, as for Make.
  - Amplitude (`mcp.eu.amplitude.com`), Mixpanel (EU and India) and Port (`mcp.us.port.io`) run a server per region. The
    directory has their default server; an account in another region adds that region's address under "Another MCP
    server". Yardlet has no region control.
- Twilio Docs (`https://mcp.twilio.com/docs`, twilio.com/docs/ai/mcp) searches and reads Twilio's public API
  documentation without a sign-in (`twilio__search`, `twilio__retrieve`). It has no account's messages or calls, which
  need Twilio's API keys and are not in the directory.
- A server that is not in the list is added by its address under "Another MCP server" in Add connector, or found in the
  registries (the "Registries" section).

Not included:

- Servers that accept only approved clients: Vercel, Canva and remote Figma (`mcp.figma.com`, which accepts only clients
  approved by the client name given at registration). Yardlet does not work around this by giving another app's name.
- Servers without a registration endpoint, which need an app registration for each client: Box, HubSpot, Asana
  `/v2/mcp`.
- Google's official MCP servers (`gmailmcp`, `calendarmcp` and `drivemcp.googleapis.com`): they need the Workspace
  Developer Preview. Instead, Yardlet runs servers with the same tool names itself (the "Google" section). Google's
  Analytics and Google Ads MCP servers run locally with Python and Application Default Credentials; Yardlet calls the
  same APIs with the account's Google sign-in instead.
- Microsoft's own MCP servers: Work IQ follows each tenant's Microsoft 365 Copilot licensing and admin policy, and
  Microsoft says its earlier per-product servers are not for new projects. Yardlet runs its own servers on Microsoft
  Graph instead (the "Microsoft 365" section).
- Unofficial Google addresses, Gmail and Drive relay servers run by other companies, and reading Slack or GitHub tokens
  from other apps.
- App Store Connect MCP servers made by other companies: their code would hold the API key. Yardlet calls Apple's API
  directly (the "Apple" section).
- Notes and Messages on the Mac: macOS has no public way for an app to read that data.
- Codex runtime plugins (documents, spreadsheets, presentations, pdf, browser and others), computer-use and node_repl:
  they are not connectors, so they stay in Codex as they are.

### Registries

Add connector also lists the servers of two public MCP registries, which share the `server.json` format: the GitHub MCP
Registry (`https://api.mcp.github.com/v0.1/servers`, the list VS Code shows, sorted by GitHub stars) and the official MCP
Registry (`https://registry.modelcontextprotocol.io/v0.1/servers`). Yardlet keeps no list of its own for them.

- Reading: the GitHub registry's list, 50 a page, when Add connector opens, and the next page as the person scrolls to
  the end; both registries for a search (`search=`, 30 each; the official one with `version=latest`), 0.4 seconds
  after typing stops. The official registry asks host apps to read it through a subregistry and to scrape it rarely,
  so Yardlet asks it only with a search. Answers stay in memory for 6 hours; nothing is written to disk. Requests are
  GETs with the search words alone.
- Counts on 2026-10-27: the GitHub registry lists 648 servers; 481 have a Streamable HTTP remote (410 with no key, 60
  with one key, 11 with an address per account) and 156 only a package. The official registry lists 50,910 latest
  entries (50,243 active): 32,575 with a Streamable HTTP remote (29,266 with no key, 3,020 with a key, 289 with an
  address per account) and 16,334 with only a package; across all its packages, npm 12,078, PyPI 4,729, Docker 1,264 and MCP bundles
  1,984. Unauthenticated GETs of each remote's metadata found, for the GitHub registry's 470 fixed addresses,
  285 with dynamic registration OAuth, 82 that answer without a sign-in, 59 that take one key, 7 that need an app of
  the person's own, 7 that accept only a client metadata document and 24 that did not answer; for 500 of the official
  registry's 32,290 fixed addresses chosen at random, 29.8% dynamic registration, 48.8% no sign-in, 9.8% one key,
  8.4% no answer. So Yardlet connects about 426 of the GitHub registry's servers by itself or with a pasted key, and
  roughly 88% of the official registry's remotes, plus programs after the person confirms them.
- What a registry says is someone else's data. An entry is kept only when its name matches the registry's pattern
  (`namespace/name`, 200 characters at most) and it is not marked deleted or deprecated. Titles and descriptions become
  one line of plain text (control, format and direction characters dropped, 80 and 240 characters at most) and are
  shown to the person, never given to a model. Addresses must be https with a host and no user info; package names,
  versions, flags, header and variable names must match their formats; an answer over 8 MB or with more than 200
  entries is not read past that. Packages from an npm or PyPI registry other than the public one are not run.
- What connecting asks (`MCPRegistryEntry.Reach`):
  - A Streamable HTTP remote with no required header connects like one added by URL: sign-in in the browser if the
    server asks (the "Connection types" section), or none.
  - A remote with one required header takes a pasted key: `Authorization: Bearer` when the registry gives that form,
    otherwise as is in the named header (`x-api-key`).
  - A package (npm, PyPI or a Docker image, stdio) opens its page (the "Programs on this Mac" section).
  - The rest say why in one line: only the old SSE transport, an address each account fills in, several headers, a
    package kind Yardlet does not run (MCP bundles, NuGet, Cargo, or bare runtime arguments whose meaning the format
    does not fix), or Docker options beyond environment variables, a loopback port and the container's own lifetime.
- Order: without a search only remotes show, the service's own first (the namespace is a domain the registry
  verified, such as `com.notion`, and the remote's host is under that domain by the public suffix list), then keys
  after sign-ins, entries in both registries, stars and title. With a search, programs and those that cannot be
  connected show too. Entries at a directory service's address are left out, since the directory shows them.

### Programs on this Mac

A connector can be a program Yardlet starts on this Mac and talks to over standard input and output (stdio): a
registry package, or a server that another app or harness starts (the "Harnesses' own servers" section).

- **Nothing runs before the person confirms.** The program's page shows where it comes from (the registry name and its
  source repository, or the app whose settings had it), the exact command line, the values it needs (secret ones
  hidden, defaults filled in), and what it can reach: it runs with the person's access to files, the network and other
  apps. Only "Run on this Mac" adds the connector, and the command it adds is the one shown.
- What runs: npm packages as `npx -y <package>@<version>`, PyPI packages as `uvx <package>==<version>`, Docker images as
  `docker run -i --rm [-e NAME …] [-p 127.0.0.1:…] <image>`, with the registry's arguments. Docker's `-e NAME=value`
  passes the value through the environment, so it is not in arguments other processes can see. A registry version is
  pinned when it names one; "latest" or none runs what the package manager resolves. Imported programs run as their
  settings say.
- Storage: the record keeps what to show (`program`: runtime, program, package, version, origin, environment names).
  The arguments and environment values are a Keychain item of kind `program`. Disconnect stops the program and keeps
  that item; Remove deletes it and the connector's folder.
- Starting: the first time a task lists or calls its tools. Yardlet finds the program in the package managers' folders,
  Homebrew, nvm's newest Node, Docker Desktop and the system (a GUI app's `PATH` lacks them). The program starts in its
  own folder, `~/Library/Caches/<bundle ID>/ConnectorPrograms/<connector ID>/`, with only `HOME`, `USER`, `LOGNAME`,
  locale, `TMPDIR`, `SHELL`, `TERM`, a `PATH` that reaches its runtime, npm's and uv's caches in that folder, and the
  person's values; nothing else of Yardlet's environment. A first `npx` or `uvx` downloads the package, so connecting
  waits up to 3 minutes. A missing runtime says what to install (Node.js, uv or Docker Desktop).
- Lifetime: it runs while Yardlet runs and stops when Yardlet quits (its standard input closes), on Disconnect or on
  Remove. Removing the connector deletes what npx and uv downloaded for it; Docker keeps the image, and the page says
  so. Nothing is written to harness or app settings.
- Updates: none on its own. A newer version is added again from the registry.
- Same server twice: a harness that starts the same package itself (`npx|@scope/name` from its settings, without the
  version) keeps its copy, and the program connector stays out of that harness's tasks (`.harnessHasIt`). A program
  without a package is not compared.

## 4. What harnesses see

- One server (`yardlet`) carries the browser tools, the task suggestion, session and scheduled-task tools, and the
  connector tools ([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) section 2). A connector tool's name is
  `<slug>_<server's tool name>`. The slug is the connector name reduced to lowercase ASCII (at most 20 characters; a
  number is added on a clash, and `browser` is not used). If a name made this way equals one of Yardlet's own tool names
  (`spawn_task` and others), that connector tool is left out of the list.
- Names are 50 characters or fewer, because Claude Code adds `mcp__yardlet__` and the model API accepts up to 64. A
  longer name uses its first part and an 8-character FNV-1a of the original name. Characters outside `[A-Za-z0-9_-]`
  become `_`.
- Titles start with `Linear: …` and descriptions with `[Linear] …`. `inputSchema`, `outputSchema` and `annotations` are
  exactly what the server gave.
- Results pass on the server's `content` items (text, images, audio, resource links and others), `structuredContent` and
  `isError` as they are. The server's JSON-RPC errors and connection failures become `isError` results.
- Injection: harnesses with an injection path always get the Yardlet MCP server. A task started with the browser tools
  off gets only the other tools, and a call to a browser tool returns an error that points to the setting.
- Tool lists are kept in `connectors.json`, so a session start does not wait for the network. A list older than 12 hours
  is read again in the background when a session asks for the list. Google and Apple services, whose tools are built
  into the app, do not ask a server, and Xcode's list is not read again, so that a re-read alone never launches Xcode
  (the "Apple" section).
- A call to a connector turned off in this task becomes an "off for this task" tool error at once. A call to a connector
  that needs sign-in returns an error saying that signing in again in Yardlet Settings → Connectors makes the same tool
  work again.
- Tool rows: tool rows in the conversation show the connector's name and icon instead of the `yardlet` server name.
  Claude `mcp__yardlet__linear_create_issue` → "Linear: create issue", Codex `yardlet · linear_create_issue` → "Linear ·
  create_issue". `ConnectorToolLabels` makes the labels from the current connector list. Old rows of a removed connector
  show the original name.

## 5. Tool lists of running tasks

When a connector is connected, disconnected or signed in again, or turned off or on in a task, running tasks get the
changed list too. Claude Code tasks get it from their next turn; tasks in other harnesses, when they next start or
resume.

- `yardlet-mcp` announces `tools.listChanged: true` in `initialize`.
- The socket between the app and the server (one request and one reply per connection) has `tools/watch`.
  - Replies to `tools/list` carry a `fingerprint` that the app computes (FNV-1a over the sorted-key JSON, and the tool
    count). Only the app computes fingerprints, so the server never re-encodes a list that crossed the socket to compare
    it, which could make notifications repeat.
  - Once 3 seconds have passed since the client first got the list, the server sends `tools/watch` with the fingerprint
    of the list the client has. The 3 seconds let the checking process that Codex `mcpServerStatus/list` starts end
    before then, so the app does not hold a connection open for that process.
  - If the task's current list differs from that fingerprint and the task is between turns, the app answers
    `{"changed": true}`. Otherwise it holds the request and answers `{"changed": false}` after 60 seconds, and the
    server asks again.
  - When the server gets a changed answer, it sends `notifications/tools/list_changed` and does not ask again until the
    client fetches the list again. So a client that does not re-read (Codex) hears it only once. Notifications are at
    least 2 seconds apart.
  - If the app cannot be reached or the token is refused (a token from an earlier run of the app), the server waits,
    starting at 15 seconds and doubling up to 5 minutes, and asks again.
- Inside the app:
  - `ConnectorCenter.onToolsChanged` calls `AgentToolBroker.toolsMayHaveChanged()` whenever the connector list or a
    per-task choice changes.
  - The broker gathers changes that arrive within 300 ms, then recomputes the current list's fingerprint for each
    watched task and answers only those that differ.
  - Tasks in a turn (`running`, `waitingForApproval`) get no answer. When `AppModel` reports the end of that task's turn
    (`ready`, `completed`, `failed`, an error event) with `taskTurnEnded`, the answer goes then. Calls to a connector
    turned off in this task are refused at once regardless.
- A tool whose name and description are unchanged is identical down to the byte. The list is built in the same order
  with the same transformation, and nothing is announced when the fingerprint is the same. Nothing is announced either
  when the server list re-read every 12 hours is the same.
- **Tools of a connector that needs sign-in again stay in the list.** This applies only to connectors that connected at
  least once and read their tools (they have `toolsUpdatedAt`). Calls return a "Needs sign-in" error, and reconnecting
  does not change the list, so the same tools work again at once in every harness, Codex included. Those that never
  connected (a service left out in the Google consent) are not in the list. Connectors the user disconnected are
  removed.
- Per harness:
  - Claude Code: on a notification from a server that announced `listChanged`, it calls `tools/list` again and uses the
    new list from the next model request. Changes during a turn are announced after the turn ends, so they apply from
    the next turn.
  - Codex: the App Server only logs this notification. `config/mcpServer/reload` and `thread/resume` of a thread already
    loaded do not restart a server whose settings are the same. So the task gets the new list when it is next opened
    (resumed). Unloading and reloading the thread (`thread/unsubscribe` and `thread/resume`) could lose background
    terminals and is undocumented behavior, so it is not used.
  - ACP harnesses: the notification is sent, but whether each harness follows it has not been checked. The UI says "when
    they next start or resume".
- The browser tools setting (on or off) is fixed when the task starts.

## 6. Harnesses' own servers

When an MCP server that a harness loads on its own and a Yardlet connector point at the same service, the model must not
get the same tools twice.

### Where they are read

When a task is injected (`AppModel.configureAgentTools` → `AppModel.connectorScope(for:)`), Yardlet reads the names and
addresses of the remote servers that the task's harness loads on its own (`ConnectorCenter.scope(for:)` →
`NativeMCPInventory.loadedRemoteServerEntries`). Addresses are normalized to a lowercase scheme and host, without the
default port, a trailing `/` or the query. Stdio servers without an address (such as the Xcode `mcpbridge` a harness
loads) are not subject to the stand-in or the duplicate exclusion below.

- Claude Code: the user servers in the task account's `.claude.json` (inside `CLAUDE_CONFIG_DIR` if set, else
  `~/.claude.json`); the local servers in the entry for the task folder (and the original folder of a worktree), minus
  `disabledMcpServers`; and the approved ones in the folder's `.mcp.json` (`enabledMcpjsonServers` and
  `enableAllProjectMcpServers`: in the project entry, the folder's `.claude/settings(.local).json` and the account's
  `settings.json`).
- Codex: the enabled entries of `[mcp_servers.*]` in `config.toml` in the task's account home.
- Other harnesses: none.

What Yardlet reads from harness settings stays in memory only, and only the parsed result (names, addresses and program
names) is kept, per file modification time. The file contents themselves, headers, environment values and queries are
not kept.

### Claude Code: Yardlet connectors take their place

- A connected Yardlet connector stands in for a harness server with the same address. When a task starts,
  `ConnectorCenter.withYardletStandIns` puts the addresses of the connectors connected at that moment (except Yardlet's
  own services such as Google) into the scope's `yardletServedURLs`. That task gets the Yardlet-side tools, and the
  Claude process drops that server for this process only with `--settings '{"deniedMcpServers":[…]}'`
  (`AgentToolServerLaunch.claudeSettings` → `ClaudeLaunchConfiguration.settings`). Account files are not written.
- There are two entries: the address exactly as the harness settings give it, and `address?*` (when it has a query). The
  CLI matches `serverUrl` with the host case-insensitively and the path and query as a `*` glob, so another path on the
  same host (for example Linear `/mcp/readonly`) stays.
- `deniedMcpServers` is merged from all settings sources, and `--settings` is the flag source among them. Claude Code's
  `mcp_toggle` is not used, because turning a server off with it writes to that folder's `.claude.json`
  `disabledMcpServers` and changes the user's settings. `--strict-mcp-config` is not used, because it drops all user
  servers.
- Why: Claude Code stores MCP sign-ins per config folder. A service registered on the Claude side needs its own sign-in
  for each account, and when the server closes the connection it reconnects only on the next turn, telling the model at
  the start of that turn that the tools went away. A Yardlet connector serves every account, folder and harness with one
  sign-in (Yardlet's Keychain), and when the server closes the connection, Yardlet reopens the MCP session, so the
  harness's tool list does not shift.
- When the Yardlet connector is not connected or needs sign-in, the harness side is used (`.harnessHasIt`). When the
  state changes, sessions already running follow from their next start or resume (`--settings` is a launch argument).
- Tool names change: `mcp__linear__save_issue` → `mcp__yardlet__linear_save_issue`. Permission rules or documents that
  name the old tool need to follow the new name.
- Turning the Yardlet side off with the per-task switch leaves that task without the service (the harness side is
  removed too). That is what the user meant by turning it off for this task.

### Codex and ACP harnesses

- A Yardlet connector with the same address is left out of that task's list, and calls to it return an error saying to
  use the harness's own server. Codex has no verified way yet to drop one server per process (thread).
- Codex plugins (ChatGPT apps) have no address, so they are not subject to the duplicate exclusion. In a Codex task the
  same service can appear both as a plugin and on the Yardlet side (the user turns plugins off in the Codex settings).

### claude.ai account connectors

- Settings → Connectors "Use claude.ai account connectors" (`Yardlet.claudeAIConnectors`, off by default). When it is
  off, Yardlet puts `ENABLE_CLAUDEAI_MCP_SERVERS=false` in the environment of the Claude Code processes it starts
  (`ClaudeProcessTransport.environment`). When it is on, Yardlet leaves it out, so the CLI default applies (a
  subscription account loads its claude.ai connectors). Nothing is written to the account settings file. Project and
  user `claude mcp add` servers are not affected.
- When it is on, the same service can appear twice, on the claude.ai side and on the Yardlet side. claude.ai connectors
  have no local address, so they are not subject to the duplicate exclusion. The UI text says so.

### Services used elsewhere

- Read in the background when Settings → Connectors opens (`NativeMCPHome.all`): the default Claude sign-in, saved
  Claude accounts, Session Switch account folders
  (`~/Library/Application Support/Session Switch/accounts/*/.claude.json`), the default and saved Codex homes,
  `~/.gemini/antigravity/mcp_config.json` and `~/.gemini/config/mcp_config.json`, and three apps that are not harnesses:
  the Claude app (`~/Library/Application Support/Claude/claude_desktop_config.json`, `mcpServers`), Cursor
  (`~/.cursor/mcp.json`, `mcpServers`) and VS Code (`~/Library/Application Support/Code/User/mcp.json` and
  `Code - Insiders`, `servers`, read with its comments and trailing commas). Read only.
- Sources: `claudeAiMcpEverConnected` in each account's `.claude.json` ("claude.ai · account", where the account is the
  address that folder's `oauthAccount` gives, or "address (organization)" for a team organization), plugins in Codex
  homes ("Codex plugin") and ChatGPT apps ("Codex app": the names in the cache Codex left, minus apps its settings
  turned off, and apps missing from the cache by their tool name prefix), and the servers in harness settings.
- What is kept: the server name, the address (without query or user info), a stdio program's path as written and npm
  package name (only scoped packages or ones containing "mcp", so command-line keys are not taken for packages), whether it is
  on, claude.ai connector names, account addresses and organization names, and Codex plugin IDs. Headers, environment
  values, queries, organization IDs and conversation history are not kept.
- Suggestions: services matched to the directory by the same address, the same host, the claude.ai name, the Codex
  plugin name or the stdio package (`ConnectorPreset.isNamed`), https remote servers that are not in the directory,
  with their name and address as they are, and programs (stdio servers) by their name, one row for the same package
  found in several places. Left out: services already connected (Google services by their API address, programs by
  package), the `yardlet` server, servers turned off there, programs inside an app's bundle (`.app/Contents/`, such as
  Codex's `node_repl`, which work only for that app), claude.ai-only entries and apps not in the directory.
- A program's arguments and environment are read only when the person presses "Review…", from that one entry in that
  file (`NativeMCPLaunch.read`, Codex's TOML included), and shown on the program's page; values the settings leave to
  something else (`${input:…}`, `${env:…}`, `${NAME}`) are left empty for the person. They are stored only if the
  person runs it. The file is never written.
- Each row has "Connect in Yardlet": a service that connects in one step is added and connected, a Google service opens
  the Google page, Slack opens the Slack page, and one that needs a key opens that field. A program's row has
  "Review…", which opens its page. "Hide"
  (`Yardlet.connectorImportDismissed`) folds the section.

### Antigravity

Antigravity tasks get no connectors (`ConnectorTaskScope.carriesConnectors`). The broker leaves them out of lists and
calls, and the composer list and the settings text say that Antigravity is not supported.

## 7. UI

- **Settings → Connectors:** a one-paragraph introduction (every harness and account, except Antigravity) → "Your
  connectors" and "Add connector" (when empty, a single one inside the empty state) → "You use these elsewhere" → "Set
  up in one go" (Google, Microsoft 365, Slack and Zoom, two to a row) → the claude.ai account connectors switch.
  - Your connectors: connected first, then in progress, needs sign-in and error (with a red reason line). The state is a
    dot and one word (`ConnectorSettingsState`), and there is one action button (Reconnect, Connect, Set up…, Try again
    or Cancel). A line under the list says when changes reach tasks (the "Tool lists of running tasks" section).
  - The row's `…`: Reload tools, Reconnect, Disconnect and Remove. Connecting with an access token or with your own
    OAuth client is there only when the service accepts it (the directory's token and client services, or servers
    outside the directory). For Google services, "Google accounts and services…" opens the Google page instead of
    Disconnect. For App Store Connect, "App Store Connect keys…" opens the keys page, and for the three Mac services,
    "Open Privacy & Security…" opens that pane of System Settings. Google and Apple services, whose tools are built into
    the app, have no Reload tools (Xcode has it).
  - A connected connector keeps its place while it signs in again or reloads its tools. If that attempt fails, it stays
    "Connected", and the reason is one gray line (`ConnectorSettingsState.note`, with a help tooltip when it does not
    fit). The Codex app and the Claude app also leave the row as it is in this case. The account rows on the Google page
    and the Slack page do the same.
- **Add connector sheet (`ConnectorAddSheet`):** a service search at the top (by name or ID, ignoring case; "Gmail",
  "Calendar" and "Drive" also find the Google line) → "Connect in one click" (dynamic registration and no-authentication
  services, the three Mac services and Xcode; clicking adds and connects) → "Paste a key or token" (GitHub and
  Browserbase have a field in the row with "Create a token on GitHub" or "Find your API key", and for App Store Connect
  "Set up…" opens its own page) → "Needs an OAuth app of your own" (folded by default) → "Another MCP server" (add by
  URL, with sign-in details in a folded optional field). When the search finds nothing, only a one-line hint and adding
  by URL remain. "From MCP registries" comes before "Another MCP server" (the "Registries" section): rows with the
  title, the service's domain when it publishes the server itself, the description and what connecting needs, and
  Connect, a key field, "Review…" for a program, or "Added".
  - A program's page (`ConnectorProgramPage`): "Run … on this Mac?", where it comes from with a link to its source,
    a warning that it runs with the person's access, the command line in monospace, the values it needs, when it runs
    and what removing leaves, Cancel and "Run on this Mac" (enabled once required values are filled).
  - When the build includes a Google app, the Google line comes first in "Connect in one click", and only Slack remains
    under "Needs an OAuth app of your own". Without one, Google and Slack are both under it, and the Google hint offers
    the claude.ai switch as an alternative.
  - When the build has a GitHub client ID, GitHub moves to "Connect in one click" and shows "Sign in with GitHub".
- **Set up in one go pages (`GoogleSetupPage`, `SlackSetupPage`):** the header shows "m of n done" or "All set", and
  each step has a numbered circle (clicking it turns the done mark on and off), a title, a one-line description, a
  console page button and copy buttons. Fields in the client step are checked as you type (a red reason line, or a green
  check when valid). A console step is done once its page has been opened or it has been marked by hand; saving the app
  marks every step done, and connecting an account completes the last step. Opened steps are kept in
  `Yardlet.connectorSetup.opened` (step names only).
  - Field checks: Google client ID `<digits>-<alphanumerics>.apps.googleusercontent.com` (entering the secret shows
    "That is the client secret"); the secret is at least 16 characters, has no spaces and is not a client ID; Slack
    client ID `digits.digits`; Slack secret (optional) is 32 hex digits.
- **The composer's "+" menu (`ComposerPlusMenu`, `ComposerMenuList`):** Add files or photos ("Add files" for a harness
  that cannot take images) · Add folder | Slash commands ▸ · Connectors ▸ (with the number that need reconnecting as a
  hint). A submenu opens in the same popover with a title and back, like "‹ Connectors". Keys: ↑↓ highlight, Return or
  Space choose, → open a list, ← back, Escape close (all at once). When the menu is opened from the keyboard, the first
  row is highlighted.
- **Connector list (`ComposerConnectorsMenu`):** Manage connectors, Add connectors | Yardlet connectors (switch rows
  first; a row that needs sign-in shows "Needs sign-in" and "Reconnect" or "Connect") | under the heading "The harness's
  own servers", the servers the harness loaded on its own (read-only, the state in one word). A server that a Yardlet
  connector stands in for shows "Uses Yardlet's connector" (gray, not counted among those to reconnect,
  `ComposerConnectorList.Row.State.yardletStandsIn`). Only when something is turned off in this task does a line say
  when a turned-off connector drops out. The connector card in the session rail on the right uses the same environment
  (`ComposerConnectorEnvironment`).
  - Per-task switch: turning a connector off is kept per task in `offInTasks` of `connectors.json` (also across Yardlet
    restarts), and removing the connector removes that choice too.
  - The rows for the harness's own servers are read-only, because turning one off would mean changing the harness's
    settings file (the "Harnesses' own servers" section).
  - Reconnect signs in from the start, but uses the previous sign-in until the new one is stored (the "Connection types"
    section). For entries that need a client or a token, clicking in the composer opens the settings.

What the person does (per service):

- Dynamic registration OAuth: Add connector → that service's "Connect" under "Connect in one click" (or "Connect in
  Yardlet" under "You use these elsewhere") → sign in and allow in the browser.
- No authentication: "Connect" in the same place. For Figma, first turn on the MCP server in the Figma desktop app → Dev
  Mode.
- Keys and tokens: "Connect" under "Paste a key or token" → create a token or key at the service and paste it.
- Google: the "Google" section; Apple (App Store Connect, the three Mac services, Xcode): the "Apple" section; Slack:
  the "Slack" section; GitHub: the "GitHub sign-in" section.
- After that, running Claude Code tasks see the tools from their next turn, and tasks in other harnesses when they next
  start or resume.

## 8. Storage

- `~/.yardlet/connectors.json`: name, slug, server address, auth type, state, the tool list and when it was read
  (`toolsUpdatedAt`), directory ID (`presetID`), your own OAuth client ID (`oauthClientID`, not a secret), scope, extra
  authorization parameters, the key's query name (`tokenQueryParameter`), server icons (`serverIcons`) and connectors
  turned off per task (`offInTasks`: task ID → connector ID), the header a pasted key goes in (`tokenHeader`), and a
  program's runtime, program name, package, version, origin and environment names (`program`). Google and Microsoft
  services have `localService`, `account` (the address) and `googleAccountID` (the account's sign-in, for both), and the
  top of the file has the `googleOAuthClientID` of the Google app the user saved and the `microsoftOAuthApp` (client ID
  and directory) of the Microsoft app the user saved (neither is a secret). Apple services have `localService`, and App Store Connect also has `account` (the key ID). The server
  address of the three Mac services is the Mac app that holds that data (`/System/Applications/Calendar.app` and
  others), and Xcode's is the path of the `mcpbridge` it found. No secrets are written. Older files are read as they are
  (new fields are empty when missing).
- Keychain: generic password, service `<bundle ID>.connectors`, account the connector UUID (for Google, the ID of the
  account sign-in), and a JSON value (kinds `oauth`, `token`, `client`, `signingKey` and `program`; a program's
  arguments and environment values; access and refresh tokens,
  expiry, client ID and secret, token endpoint and auth method, resource, and for Microsoft the scope a refresh names
  again (`refreshScope`); `signingKey` holds App Store Connect's key ID,
  issuer ID and PEM). `client` is what is left before sign-in or after a disconnect: only your own client. The ID and
  secret of the Google app the user saved are a single item under the same service with a fixed account
  (`GoogleOAuth.appCredentialID`). The Google app built into the build is not written to Keychain.
- Ad-hoc builds also have an identifier-based designated requirement, so no keychain permission prompt appears after an
  update. QA bundles have a different bundle ID, so their items do not mix.
- Keychain calls run off the main thread, so the UI does not freeze while the keychain waits for a system prompt.
- Disconnect deletes the token (and keeps your own client). Remove deletes the Keychain item. Yardlet does not ask the
  server to revoke tokens (RFC 7009). Permissions that macOS gave for the three Mac services stay after removal (the
  "Apple" section).
- The icon cache is in `~/Library/Caches/<bundle ID>/ConnectorIcons/` (the "Icons" section). Program connectors work in
  `~/Library/Caches/<bundle ID>/ConnectorPrograms/<connector ID>/`, which Remove deletes.

## 9. Google

Gmail, Google Calendar, Google Drive, Google Analytics and Google Ads are not remote MCP servers but servers that Yardlet
runs inside the app.
Harnesses get them through the `yardlet` MCP server (`yardlet-mcp` → socket → app) like other connectors, so tokens do
not leave Yardlet, and injection, the per-task switch and the Antigravity exclusion are the same. Tool names and
arguments follow Google's official MCP servers (the ones claude.ai's Google connectors use). The Google Drive connector
also provides tools that read and edit the structure inside Docs, Sheets and Slides files (see "Tools" below).

### Google app

- **App in the build:** `scripts/build-app.sh` reads `YARDLET_GOOGLE_CLIENT_ID` and `YARDLET_GOOGLE_CLIENT_SECRET` from
  the environment, or else `Packaging/GoogleOAuthClient.json` (the `{"installed": {...}}` shape Google lets you
  download, or `{"client_id", "client_secret"}`; an example is `Packaging/GoogleOAuthClient.example.json`), and puts
  `YardletGoogleOAuthClientID` and `YardletGoogleOAuthClientSecret` into the bundle's Info.plist. The file is in
  `.gitignore`, and the values are not printed to the log (only whether they were added). A desktop client's secret
  ships inside an installed app, so Google does not treat it as a secret either, but it is kept out of the repository.
  This lets others build with their own client.
- `GoogleOAuth.BuiltInApp.from(info:)` reads it from Info.plist (trimming whitespace; none without an ID), and it comes
  in through `ConnectorCenter.Environment.googleBuiltInApp`. Without an Info.plist, as with `swift run` or tests, there
  is none.
- **App used for sign-in:** the app the user saved (Keychain `appCredentialID`) if there is one, else the app in the
  build, else none (`noApp`). `canSignInWithGoogle` turns on the sign-in, add-account and connect buttons. An account's
  credentials keep the client it signed in with, so after the app changes, accounts already signed in keep refreshing
  with their own client (if the old client is deleted in Google Cloud, they become "Needs sign-in").
- **Google page:** when the build has an app and the user has none, there is one step, "Sign in with each Google
  account", with service checkboxes and "Sign in with Google". Below it are a note about the warning shown for an app
  Google has not verified and a "Use a Google OAuth app of your own…" link, which opens the seven steps (see "Your own
  Google app"). Once the user saves an app, that app is used; removing it brings back the app in the build. When an app
  is saved, the steps fold into one line ("Google OAuth app saved in your keychain · client ID", with Setup steps and
  Change…).
- **Google's policies (official docs):** an app that requests sensitive or restricted scopes shows the "Google hasn't
  verified this app" screen on each account's first sign-in until Google verifies it, and is limited to 100 new users.
  Refresh tokens of an external app whose publishing status is "Testing" expire after 7 days. "In production" has no
  fixed expiry; instead a token becomes invalid when the user revokes access, after 6 months without use, when the
  password changes (for tokens with Gmail scopes), and when one account and one client have more than 100 refresh tokens
  (oldest first).

### Accounts and services

- The Google services are five of `LocalConnectorService`: `gmail`, `googleCalendar` (`google-calendar`),
  `googleDrive` (`google-drive`), `googleAnalytics` (`google-analytics`) and `googleAds` (`google-ads`)
  (`LocalConnectorService.google`, `isGoogle`, `accountProvider` `.google`). Their directory entries use
  `SignIn.googleAccount`, and their addresses are `https://gmail.googleapis.com/gmail/v1/`,
  `https://www.googleapis.com/calendar/v3/`, `…/drive/v3/`, `https://analyticsadmin.googleapis.com/v1beta/` and
  `https://googleads.googleapis.com/v26/`.
- A new account starts with Gmail, Calendar and Drive (`LocalConnectorService.googleDefaults`). Analytics and Ads ask for
  more, so their scopes are asked for only when the person turns them on for an account.
- **One account, one connector per service:** each service of a Google account is its own `ConnectorRecord` (the
  per-task switch, tool rows and reconnect are per service), and they share one sign-in:
  `ConnectorRecord.accountSignInID` (the Keychain item of that account's sign-in; saved as `googleAccountID`, its name
  from when only Google accounts had one), `credentialID = accountSignInID ?? id`. The account's first service is stored
  under its own ID. `ConnectorCenter.accounts(.google)` (`googleAccounts`) groups them by `credentialID`. Microsoft
  accounts use the same machinery (the "Microsoft 365" section).
- **One sign-in:** the fixed loopback `127.0.0.1:47823/callback` → `accounts.google.com/o/oauth2/v2/auth` in the default
  browser. It requests the scopes of all services turned on for that account at once (in directory order) and sends
  `include_granted_scopes=true`, `access_type=offline`, `prompt=select_account consent` for a new account,
  `prompt=consent` and `login_hint=<address>` for a sign-in again, PKCE S256 and `state` (`resource` is not sent).
  Tokens come from `oauth2.googleapis.com/token`, with the secret sent in the form. A missing refresh token is reported
  as a failure.
- **Account address:** taken from the Gmail profile's `emailAddress`, else the primary calendar (the `id` of
  `users/me/calendarList/primary`), else Drive `about`'s `user.emailAddress`, else the OpenID user info's `email` (for an
  account with only Analytics or Ads, whose scopes include `userinfo.email` for this). An address
  that already exists joins that account (for a service it already has, the new row is dropped). A new sign-in is stored
  only after its address has been read with a separate session. So when a reconnect brings a different account, that
  sign-in is not stored and only the reason is kept, and the account's previous sign-in, state and tools stay as they
  are (a connected account shows "Connected" and a reason line). If the user cancels the first sign-in in Yardlet or on
  Google's page, that row is deleted; cancelling a reconnect changes nothing. Other failures stay, with their reason.
- **Partial grants:** when granular consent leaves out one service, only that service gets "Needs sign-in" with a reason
  such as "Google did not grant access to Google Drive", and its tools drop out. Granting nothing is not a sign-in.
- **Turning on and off:** turning on connects at once when the sign-in already has the scopes; otherwise only that
  account consents again (incremental authorization). Turning off deletes that service's connector, and the sign-in
  stays while another service uses it (even when the first service is turned off). The Keychain item is deleted with the
  last service. Yardlet does not revoke scopes at Google (the user revokes them under third-party access in their Google
  Account).
- **Names:** the first account's slugs are `gmail`, `calendar`, `drive`, `analytics` and `google_ads`; when a name is
  already taken, the first part
  of the address is added (`gmail_<prefix>`). Tool titles and descriptions are `Gmail · address: …` and
  `[Gmail · address] …`. The tool list is built into the app, so no server is asked.
- **Refresh (`OAuthAPISession`):** before a call when the token expires within 1 minute, and on a 401 it refreshes once
  and sends again. One refresh runs at a time per account. When Google refuses a refresh with `invalid_grant` (access
  revoked, 6 months unused, password changed, 7 days in Testing status), that account becomes "Needs sign-in", settings
  and the composer show "Reconnect", and calls return a tool error saying to sign in again. A network failure is only
  that call's error and does not change the state.
- **Reconnect and remove:** reconnecting a Google service signs in the whole account again. Remove removes only that
  service, and "Remove this Google account" removes the whole account. Yardlet does not ask Google to revoke tokens.
- Google account row: the address, five service chips (on or off, and state), and Reconnect and `…` when needed. Below
  them is "What Yardlet asks Google for" (the scopes and their classes).

### Scopes

| Service | Scope | Class | Why |
|---|---|---|---|
| Gmail | `gmail.modify` | restricted | Read, draft, send and label. Changing labels (`threads.modify`, `messages.modify`) accepts only `mail.google.com` and `gmail.modify`. There is no permanent delete |
| Calendar | `calendar.calendarlist.readonly` | sensitive | `list_calendars` (calendarList.list) |
| Calendar | `calendar.events` | sensitive | Read, create, change, delete and respond to events in all calendars |
| Calendar | `calendar.events.freebusy` | sensitive | `suggest_time` (freeBusy.query) |
| Drive | `drive.readonly` | restricted | Read and export all files, and read the structure inside Docs, Sheets and Slides |
| Drive | `drive.file` | non-sensitive | Create and copy, and change only files Yardlet created (including editing Docs, Sheets and Slides) |
| Analytics | `analytics.readonly` | sensitive (see below) | Read accounts, properties, Ads links, custom definitions and reports |
| Analytics, Ads | `userinfo.email` | non-sensitive | The address of an account that has none of Gmail, Calendar and Drive |
| Ads | `adwords` | restricted | Google Ads has no narrower scope; Yardlet only lists customers and runs GAQL `SELECT`s |

- Google's public lists do not name the class of `analytics.readonly`; the table follows the Cloud console's Data Access
  page, which is where to check it. Google's Ads guide lists `adwords` as restricted
  (developers.google.com/google-ads/api/docs/productionize/secure-credentials). It also covers changing campaigns and
  budgets, so reading only is the code's to keep: the Ads tools reach only `customers:listAccessibleCustomers`,
  `googleAds:search` with a query checked to be a `SELECT`, and `googleAdsFields:search`.
- Scopes are prefixed with `https://www.googleapis.com/auth/`. The full `drive`, `calendar` and
  `https://mail.google.com/` scopes are not requested. So Yardlet cannot change or delete the person's other Drive
  files, and the Drive tools have no delete.
- **Docs, Sheets and Slides are called with the two Drive scopes too.** The reading methods (Docs `documents.get`,
  Sheets `spreadsheets.get` and `spreadsheets.values.get`, Slides `presentations.get`, `presentations.pages.get` and
  `presentations.pages.getThumbnail`) accept `drive.readonly`, and the editing methods (Docs `documents.batchUpdate`,
  Sheets `spreadsheets.values.update` and `spreadsheets.batchUpdate`, Slides `presentations.batchUpdate`) accept
  `drive.file` (each method's "Authorization scopes"). So the `documents`, `spreadsheets` and `presentations` scopes
  (sensitive) are not requested, and these tools add no scopes to the consent screen.
- **Docs, Sheets and Slides that can be edited:** `drive.file` reaches only files created or opened with the app, or
  shared with the app through Google Picker or the app's file picker. Yardlet has no Picker, so what it can edit is
  files that Yardlet created or copied. For other files, Google's 403 ("The caller does not have permission") becomes
  the tool error as is. Such a file is edited by making a copy with `copy_file`.
- **Enabling APIs:** apart from the scopes, the Docs API (`docs.googleapis.com`), Sheets API (`sheets.googleapis.com`)
  and Slides API (`slides.googleapis.com`) must be enabled in the Cloud project the OAuth client belongs to. When one is
  off, Google's 403 ("… API has not been used in project … before or it is disabled") becomes that tool's error.
  Enabling an API does not change the scopes or the consent screen. The API step in "Your own Google app" enables six
  APIs on one page (`ConnectorSetupAssistant.googleAPIs`).
- Sources: the restricted scope list support.google.com/cloud/answer/13464325, Gmail scopes
  developers.google.com/workspace/gmail/api/auth/scopes, Drive scopes
  developers.google.com/workspace/drive/api/guides/api-specific-auth, Calendar scopes
  developers.google.com/workspace/calendar/api/auth (it has no class column; they are not on the restricted list, and
  the Cloud console marks them sensitive), the Docs, Sheets and Slides methods
  developers.google.com/workspace/docs/api/reference/rest/v1/documents, …/sheets/api/reference/rest/v4/spreadsheets,
  …/slides/api/reference/rest/v1/presentations, and the classes of their scopes …/docs/api/auth, …/sheets/api/scopes,
  …/slides/api/scopes.

### Tools

Gmail (`GmailToolCatalog`, `GmailToolRunner`, Gmail API v1):

| Tool | Gmail API | What it does |
|---|---|---|
| `search_threads` | `GET users/me/threads?q&maxResults&pageToken&includeSpamTrash` + `threads/{id}?format=metadata` for each thread | Gmail search syntax, 1–50 per page (default 20). Thread ID, message count, and for the latest 10 messages the sender, recipients, date, subject, snippet, labels and unread state. No body. Threads are fetched 5 at a time in parallel |
| `get_thread` | `GET users/me/threads/{id}?format=full` or `metadata` | `messageFormat`: `PLAIN_TEXT` (default: body text and attachment names), `FULL_CONTENT` (+HTML), `MINIMAL`, `METADATA_ONLY` |
| `get_message` | `GET users/me/messages/{id}` | The same formats |
| `list_labels` | `GET users/me/labels` | id, name, type |
| `create_draft` | `POST users/me/drafts`; with attachments, `POST upload/gmail/v1/users/me/drafts?uploadType=multipart` | to, cc, bcc, subject, body, htmlBody, replyToMessageId, attachments. For a reply: that thread, `In-Reply-To` and `References`, a "Re:" subject, and Reply-To or From when there are no recipients |
| `send_draft` | `POST users/me/drafts/send` | Draft ID |
| `send_message` | `POST users/me/messages/send`; with attachments, `upload/…/messages/send` | The same fields as create_draft, recipients required |
| `modify_labels` | `POST users/me/threads/{id}/modify` or `messages/{id}/modify` | One of `threadId` or `messageId` + `addLabelIds` and `removeLabelIds`. Removing INBOX = archive, removing or adding UNREAD = read or unread |
| `delete_draft` | `DELETE users/me/drafts/{id}` (for a `messageId`, `GET users/me/drafts` first, 500 at a time) | One of `draftId` or `messageId` (a message `get_thread` shows with the DRAFT label). Deletes it for good, not to the trash |

- Body: decoded by the part's charset (EUC-KR and others), HTML-only converted to text, 40,000 characters per message.
  Outgoing mail has a UTF-8 base64 body, non-ASCII subjects and display names in RFC 2047, and HTML together with a text
  part in `multipart/alternative`. Addresses with a line break or a comma are refused before sending (header injection).
  Gmail fills in From.
- Attachments (`GmailAttachmentFiles`): the agent gives absolute paths of local files (`~/` works), and the connector
  reads them and attaches them after the body in `multipart/mixed`. Files come only from the task's folders
  (`ConnectorToolContext.workspaceRoots`, the same list browser uploads use), the temporary folders (`/tmp` and
  `$TMPDIR`, where agents keep files they make, such as Claude Code's scratchpad) and the person's Desktop, Documents
  and Downloads, never from a hidden file or folder below them (`.env`, `.ssh`, `.git`). `..` and symbolic links are
  resolved with `realpath` before the check. Only regular files, up to 25 MB in all (Gmail's attachment limit); more is
  refused before anything is read. The MIME type comes from the extension (`UTType`, else
  `application/octet-stream`), and UTF-8 text gets `charset="UTF-8"`. File names are composed to NFC (macOS keeps
  Korean names decomposed) without control characters, and a non-ASCII name goes in `name` and `filename` as RFC 2047
  encoded words, as Gmail's web client sends it. A message with attachments goes through the upload endpoint (up to
  35 MB) as a JSON metadata part and a `message/rfc822` part instead of JSON `raw`. The result lists each attached
  file's name, type and size.
- Labels use one `modify_labels` instead of the five tools on the claude.ai side.

Calendar (`GoogleCalendarToolRunner`, Calendar API v3):

| Tool | API | Notes |
|---|---|---|
| `list_calendars` | `GET users/me/calendarList` | id, name (the user's own name for it first), time zone, access role, primary |
| `list_events` | `GET calendars/{id}/events` | `singleEvents=true`, by default the next 7 days, `orderBy` startTime or updated (startTimeDesc reverses that order), `q`=fullText, `eventTypes`, at most 250 |
| `search_events` | `GET calendars/primary/events?q=` | One year before and after, by start time. Google's MCP does semantic search, but the public API does word search |
| `get_event` | `GET calendars/{id}/events/{id}` | |
| `suggest_time` | `POST freeBusy` | Merges the busy times of the account (`primary`) and the attendees, and within working hours and excluding weekends, suggests times on 15-minute steps, an hour apart, 5 by default. Calendars it cannot see are in `unavailableCalendars` |
| `create_event` | `POST calendars/{id}/events` | Time zone, all-day (end date included), attendees, Meet (`conferenceDataVersion=1`), recurrence, reminders, busy or free, visibility; `sendUpdates` defaults to all |
| `update_event` | `PATCH …/events/{id}` | Only the changed fields. Moving only the start keeps the length; attendees are added and removed by email (with a GET first in that case) |
| `delete_event` | `DELETE …/events/{id}` | |
| `respond_to_event` | `PATCH attendees` after a GET | Changes only the account's own attendee entry. An event the account was not invited to is an error |

- Times: a time without an offset (`2026-04-30T10:00:00`) is read in the `timeZone` argument, or this Mac's time zone
  when there is none, and Google gets both the offset and `timeZone`. Argument names are Google MCP's (`calendarId`,
  `startTime`, `attendeeEmails`, `addGoogleMeetUrl`, `notificationLevel` and others).

Drive (`GoogleDriveToolRunner`, Drive API v3, `supportsAllDrives`):

| Tool | API | Notes |
|---|---|---|
| `search_files` | `GET files?q=` | Turns Google MCP's query terms into Drive's: `title`→`name`, `parentId = 'x'`→`'x' in parents`, `owner = 'x'`→`'x' in owners`, `!=` to `not`. Words without an operator become `fullText contains`. Trash excluded |
| `list_recent_files` | `GET files?orderBy=` | recency, lastModified (`modifiedTime desc`), lastModifiedByMe |
| `get_file_metadata` | `GET files/{id}` | Google MCP names (`title`, `fileSize`, `owner`, `parentId`, `viewUrl`) |
| `get_file_permissions` | `GET files/{id}/permissions` | |
| `read_file_content` | Export or `alt=media` | Docs as Markdown (text if that fails), Sheets as CSV of the first sheet, Slides as text, text files as they are, cut at 100,000 characters, comment threads with `includeComments`. PDF, Office and images return an error saying to use download_file_content (Google MCP reads them, but the public API does not offer this) |
| `download_file_content` | Export, `alt=media` or revisions | base64, up to 5 MB (checks the size first and refuses) |
| `create_file` | Multipart upload or metadata only | Converts text, CSV and Office to Google formats (`disableConversionToGoogleType`); without content, an empty Docs, Sheets or Slides file, or a folder |
| `copy_file` | `POST files/{id}/copy` | |
| `update_file` | `PATCH` (multipart) | A tool Yardlet adds: name, description, folder, content. Because of `drive.file`, only files Yardlet created or copied change, and for other files Google's 403 text becomes the error as is |

Docs, Sheets and Slides (`GoogleEditorsToolCatalog`, `GoogleEditorsToolRunner`, Docs API v1, Sheets API v4, Slides API
v1):

- **They are tools of the Drive connector.** Their scopes are the same as Drive's and their files are Drive files, so
  they have no service row, chip, sign-in or per-task switch of their own. The Drive connector provides the nine above
  and these twelve, 21 in all (`drive_*`). The first account has `drive_read_doc`, and later accounts
  `drive_<prefix>_read_doc`.
- **Names and arguments:** they follow the tool names and argument names of Google's official Docs, Sheets and Slides
  MCP servers (`docsmcp`, `sheetsmcp` and `slidesmcp.googleapis.com`): `documentId`, `requests`, `writeControl`,
  `spreadsheetId`, `range`, `values`, `formulas`, `sheetId`, `presentationId`, `pageId`, `fields`, `commentsIncluded`
  and `thumbnailProperties`. The paging arguments and `valueRenderOption` are Yardlet's additions.

| Tool | API | Notes |
|---|---|---|
| `read_doc` | `GET documents/{id}?includeTabsContent=true` | For each paragraph, the start and end index (UTF-16), text, style (`HEADING_1`…; omitted for normal text), list (`listId`, `nestingLevel`) and web links. Tables give each cell's text and its indexes. Objects such as images and footnote marks are one U+FFFC per index, so the text length equals the index length. With several tabs, a `tabs` list and selection by `tabId` (child tabs included). `revisionId`, and Drive comments with `commentsIncluded` |
| `update_doc` | `POST documents/{id}:batchUpdate` | The request list as is (`insertText`, `deleteContentRange`, `replaceAllText`, `updateParagraphStyle`, `createParagraphBullets`, `insertTable` and others), all or nothing. `writeControl` (`requiredRevisionId`, `writeMode: SUGGEST`) is passed as is too |
| `get_spreadsheet` | `GET spreadsheets/{id}` | By default a field mask for the title, locale and time zone, each sheet's ID, name, size, frozen rows and columns, hidden state and type, and named ranges. With `fields` or `includeGridData`, the Sheets API JSON as is (over 100,000 characters, an error saying to narrow the range) |
| `get_values` | `GET spreadsheets/{id}/values/{range}` | By row. `valueRenderOption` `FORMATTED_VALUE` (default), `UNFORMATTED_VALUE` or `FORMULA` (reads formulas) |
| `update_values` | `PUT …/values/{range}?valueInputOption=RAW` | Values as they are: numbers are numbers, and text starting with `=` is text. null leaves the cell as it is, and `""` clears it |
| `update_formulas` | `PUT …/values/{range}?valueInputOption=USER_ENTERED` | Formulas, and values read as if a person typed them |
| `insert_dimension` | `POST spreadsheets/{id}:batchUpdate` (`insertDimension`) | Inserts empty rows or columns (from 0, end excluded) |
| `update_spreadsheet` | `POST spreadsheets/{id}:batchUpdate` | The request list as is (`addSheet`, `deleteSheet`, `updateSheetProperties`, `repeatCell`, `mergeCells`, `sortRange` and others). The reply's `replies` (new sheet IDs and others) |
| `read_presentation` | `GET presentations/{id}?fields=…` | For each slide, the ID, order, layout name and whether it is skipped; for each element, the ID, kind (shape, table, image, group, sheetsChart, wordArt…), placeholder (`TITLE`, `BODY`) and text; cell text for tables; speaker notes and their object ID. With `fields`, the Slides API JSON as is |
| `read_slide_page` | `GET presentations/{id}/pages/{pageId}` | The elements of one page (slide, layout or master), with size and position (`size`, `transform`) |
| `read_slide_page_thumbnail` | `GET …/pages/{pageId}/thumbnail` | PNG, `thumbnailProperties.thumbnailSize` (SMALL, MEDIUM or LARGE, default MEDIUM). The size and address, and the PNG itself as image content (up to 5 MB). The image address is a 30-minute address Google signed for the account, so it is fetched without the Google token |
| `update_presentation` | `POST presentations/{id}:batchUpdate` | The request list as is (`createSlide`, `insertText`, `deleteText`, `replaceAllText`, `createShape`, `updateTextStyle`, `deleteObject` and others), `writeControl` |

- **Paging:** replies are cut so they stay within 100,000 characters (the same limit as `read_file_content`). Documents
  are cut by element, with a `nextStartIndex` (call again with `startIndex`; tables continue by row, with `firstRow`
  when not from the first). Sheets are cut by row, with `rowsReturned` and a `nextRange` computed from the range Google
  returned (for example, when `Data!A1:D3000` gives 1,850 rows, `Data!A1851:D3000`). Slides are cut by slide, with
  `nextStartSlide` (call again with `startSlide`).
- **IDs:** when given a link (`…/document/d/<ID>/edit`), only the ID is used. Arguments are checked before the request
  (empty `requests`, a row whose cells are not an array, an end that is not past the start or a wrong
  `valueRenderOption` is an error without a request).
- Which files the editing tools can reach, and which APIs must be enabled, are in "Scopes".

Google Analytics (`GoogleAnalyticsToolCatalog`, `GoogleAnalyticsToolRunner`, Analytics Admin and Data APIs v1beta). Names
and arguments follow Google's own Analytics MCP server (github.com/googleanalytics/google-analytics-mcp), whose
arguments are snake case:

| Tool | API | Notes |
|---|---|---|
| `get_account_summaries` | Admin `GET accountSummaries` | Every page, up to 2,000 accounts |
| `get_property_details` | Admin `GET properties/{id}` | `property_id` is `123` or `properties/123` |
| `list_google_ads_links` | Admin `GET properties/{id}/googleAdsLinks` | |
| `get_custom_dimensions_and_metrics` | Data `GET properties/{id}/metadata` | Only those with `customDefinition` |
| `run_report` | Data `POST properties/{id}:runReport` | `date_ranges`, `dimensions`, `metrics`, `dimension_filter` and `metric_filter` (FilterExpression as the API takes it), `order_bys`, `limit` (default 1,000), `offset`, `currency_code`. Rows come back as `headers` and lists of values |
| `run_realtime_report` | Data `POST properties/{id}:runRealtimeReport` | The same without dates |

Google Ads (`GoogleAdsToolCatalog`, `GoogleAdsToolRunner`, Google Ads API v26). Names follow Google's own Google Ads MCP
server (developers.google.com/google-ads/api/docs/developer-toolkit/mcp-server). Developer tokens ended on 2026-09-09, so
none is sent:

| Tool | API | Notes |
|---|---|---|
| `list_accessible_customers` | `GET customers:listAccessibleCustomers` | |
| `search` | `POST customers/{id}/googleAds:search` | `customer_id` (dashes dropped), `query` (refused without a request unless it starts with `SELECT`), `login_customer_id` as the `login-customer-id` header, `page_token` |
| `get_resource_metadata` | `POST googleAdsFields:search` | The fields under a resource name, with whether each can be selected, filtered and sorted |

- Analytics and Ads answers over 100,000 characters become an error that says how to narrow the request.
- Descriptions say only what the tool does, in under 260 characters. Annotations: reading tools have
  `readOnlyHint: true` and `openWorldHint: false`, sending and writing tools `openWorldHint: true`, and `modify_labels`,
  `delete_draft`, `delete_event`, `update_file` and the Docs, Sheets and Slides writes other than `insert_dimension`
  have `destructiveHint: true`.
- Bodies, requests and responses are not written to the log. Errors show only Google's `error.message` and the HTTP
  status ("Gmail: Requested entity was not found. (HTTP 404)").

### When the harness asks

- Tools that ask follow the harness's approval settings. Yardlet keeps no approval rules of its own and puts annotations
  (`destructiveHint` and others) on write tools.
- Claude Code: connector tools are not in `--allowedTools`, so the CLI asks according to the task's permission mode. The
  request cards for write tools (Gmail `send_draft`, `send_message`, `modify_labels` and `delete_draft`, Calendar `create_event`,
  `update_event`, `delete_event` and `respond_to_event`, Drive `create_file`, `copy_file`, `update_file`, `update_doc`,
  `update_values`, `update_formulas`, `insert_dimension`, `update_spreadsheet` and `update_presentation`;
  `LocalConnectorService.approvalRequiredTools`) use Yardlet's text and have no "Always allow" (`GmailToolApproval`,
  `GoogleToolApproval`): mail shows the recipients, cc, bcc, subject, attachments (the total, then each file's name
  and size, up to 20, or "not found" when it is not on disk) and the first 1,200 characters of the body; a card that
  sends or deletes a draft first reads the draft from Gmail (`GmailDraftReader`, up to 5 seconds, while that session's
  next frames wait) and shows its recipients, subject, last saved time, attachments and body instead of an ID, or the
  ID and "could not read" when Gmail did not answer; labels
  show the thread, what is added and removed, and archive, read or unread; events show the title, date and time,
  invitees, Meet, and whether Google sends mail; Drive shows the title, type, folder and the first 600 characters of the
  content. Docs, Sheets and Slides show "Allow Claude to change a document (a spreadsheet, a presentation) in
  {address}'s Drive?" with the file ID, the range, what changes ("insertText ×2, updateParagraphStyle") and the first
  600 characters of the inserted text or cell values, and inserting rows or columns states the count, as in "Inserts 2
  rows." Other tools get the CLI's usual card. In bypass permissions mode nothing is asked (the harness's own behavior).
- Codex: Yardlet does not set `approval_mode` on its server's tools. Codex decides whether to ask from the task's
  approval settings and the tool annotations.
- ACP: that harness's MCP approval, as is.

### Your own Google app

Someone whose build has no Google app, or who wants to use their own app, creates one OAuth app in Google Cloud. Google
under "Set up in one go" in Settings → Connectors opens the steps below in order.

1. **New Project** (console.cloud.google.com/projectcreate): create a project.
2. **Enable APIs**: on one page
   (`flows/enableapi?apiid=gmail.googleapis.com,calendar-json.googleapis.com,drive.googleapis.com,analyticsadmin.googleapis.com,analyticsdata.googleapis.com,googleads.googleapis.com,docs.googleapis.com,sheets.googleapis.com,slides.googleapis.com`),
   enable the nine APIs. The Drive connector's Docs, Sheets and Slides tools use the last three.
3. **Google Auth Platform**: app name (copy button), user support email, audience, contact information. To use personal
   Gmail accounts, the audience is **External**. If only accounts of one Workspace organization are used and the project
   is inside that organization, **Internal** works too (no verification screen and no 100-user limit).
4. **Audience** → Publish app → "In production" (for External). Left at "Testing", it needs a new sign-in every 7 days.
5. **Data Access** → Add or remove scopes → paste the nine scopes (copy button) into Manually add scopes, then Update and
   Save. Analytics' and Ads' scopes are asked for only on accounts that turn those services on.
6. **Create client**: type Desktop app → paste the client ID and client secret into Yardlet's fields (the format is
   checked) and **Save**. If you create a Web application instead, add `http://127.0.0.1:47823/callback` to the
   authorized redirect URIs.
7. Choose the services and **Sign in with Google** → choose the account → in "Google hasn't verified this app", Advanced
   → go to the app → allow the services. For a second account, **Add another Google account**. Turn services on and off
   per account with the service chips.

If the Workspace Admin console blocks Gmail access by unverified third-party apps, the sign-in is refused. In that case,
add this app's client ID to the trusted list in the Admin console (Security → API controls), or use an internal app for
that organization only.

### Not included

- Gmail: downloading attachments and sending with attachments, trash and spam, creating and editing labels, and listing,
  editing and deleting drafts.
- Drive: reading the body of PDF, Office and image files (download them and read them separately), deleting files, and
  changing sharing.
- Docs, Sheets and Slides: editing in place a file Yardlet did not create or copy. That would need requesting the
  `documents`, `spreadsheets` and `presentations` scopes (sensitive) or the full `drive` scope (restricted), or a Google
  Picker screen where the person picks the file. For now, Yardlet edits a copy.
- Calendar: `search_events` is word search, not semantic search. The time zone is this Mac's (reading the time zone in
  the calendar settings needs another scope).
- Analytics: annotations, audiences, funnel reports (v1alpha) and any change to a property. Ads: anything that changes
  an account (mutates), and keyword planning.

## 10. Apple

App Store Connect, the Mac's calendars, reminders and contacts, and Xcode are not remote MCP servers either, but servers
that Yardlet runs inside the app (`appStoreConnect`, `appleCalendar`, `appleReminders`, `appleContacts` and `xcode` of
`LocalConnectorService`). Like Google, they go into the tasks of every harness and account through the one `yardlet` MCP
server, and the per-task switch, tool row labels and the Antigravity exclusion work as for other connectors.

### Structure

| Connector | Directory sign-in type | What it calls | Tool names |
|---|---|---|---|
| App Store Connect | `appStoreConnectKey` (API key) | Apple's App Store Connect API (`https://api.appstoreconnect.apple.com/`, JSON:API) | `app_store_connect_*`; with two keys, the second key's are `app_store_connect2_*` |
| Apple Calendar | `macPermission` (macOS permission) | Calendars in EventKit (`EKEventStore`) | `apple_calendar_*` |
| Apple Reminders | `macPermission` | Reminders in EventKit | `apple_reminders_*` |
| Apple Contacts | `macPermission` | Contacts (`CNContactStore`) | `apple_contacts_*` |
| Xcode | `localApp` (an app on this Mac) | Xcode's MCP server (from Xcode 26.3), through the stdio bridge `mcpbridge` | `xcode_<Xcode's tool name>` (`xcode_BuildProject`) |

- The tools of App Store Connect and the three Mac services are built into the app, so no server is asked. Xcode's tools
  are the list the Xcode server gives as is, read when connecting and kept in `connectors.json`. Tool descriptions are
  under 260 characters.
- Icons: for the three Mac services and Xcode, the icon macOS gives that app (no network); for App Store Connect, the
  icon from Apple's developer site (the "Icons" section).

### App Store Connect

- Yardlet calls Apple's official API itself, with the person's API key. It does not go through another company's MCP
  server.
- **Key types** (Apple's "Creating API Keys for App Store Connect API"): only Account Holder and Admin can create team
  keys; a role is chosen at creation, and they reach all apps. Individual keys follow that user's permissions and cannot
  be used for certificates and profiles, sales and finance, or notarization (`notaryTool`). The `.p8` file can be
  downloaded only once.
- **Tokens** (Apple's "Generating Tokens for API Requests"): header `alg: ES256`, `kid` (key ID) and `typ: JWT`; payload
  `aud: appstoreconnect-v1`, `iat` and `exp`; `iss` (issuer ID) for a team key, and `sub: "user"` without `iss` for an
  individual key. Apple's lifetime limit is 20 minutes, so tokens are made for 15 minutes, and a new one is made 1
  minute before the old one ends. The signature is P-256's R‖S (64 bytes). The engine has only the contract
  (`ES256Signing`), and the CryptoKit implementation (`MacES256Signer`) is in the macOS layer. A build that cannot sign
  has no App Store Connect in the directory.
- **Refusal:** on a 401, the request is sent once more with a new token. Another 401 means the key was revoked or an ID
  is wrong, so the connector becomes "Needs sign-in", and the row's action is "Set up…", which opens the page to enter
  the key again.
- **Key storage:** the `.p8` file chosen on the page is read when "Connect" is pressed, checked to be a key, and kept in
  Keychain (`signingKey` in the "Storage" section). `connectors.json` has only the key ID. The key value is never in the
  UI, logs, the model or ordinary files. Reading the app list once (`GET /v1/apps?limit=1`) checks the key, and when
  that works, a line on the page asks whether to move that `.p8` file to the Trash (Move to Trash, Keep the File). No
  dialog is stacked over the sheet. The key ID is filled in from the file name (`AuthKey_<key ID>.p8`). Entering the
  same key ID again replaces that key.
- **14 tools** (9 read, 5 write; `AppStoreConnectToolCatalog`, `AppStoreConnectToolRunner`):

| Tool | API | Notes |
|---|---|---|
| `list_apps` | `GET /v1/apps` | Name, bundle ID, SKU, primary locale; filter by `bundleId` and `name` |
| `list_builds` | `GET /v1/builds?filter[app]` + `include=preReleaseVersion,buildBetaDetail` | Latest uploads first. `version` (marketing version), `buildNumber`, processing state, expiry, TestFlight internal and external state |
| `list_beta_groups` | `GET /v1/betaGroups?filter[app]` | Internal and external, public link |
| `list_beta_testers` | `GET /v1/betaTesters?filter[betaGroups]` or `filter[apps]` | Name, email, invitation type, state |
| `list_beta_feedback` | `GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions` and `…CrashSubmissions` | Both merged, newest first: device, build, comment, screenshot addresses |
| `get_beta_crash_log` | `GET /v1/betaFeedbackCrashSubmissions/{id}/crashLog` | `logText` up to 100,000 characters |
| `list_customer_reviews` | `GET /v1/apps/{id}/customerReviews?include=response` | Filter by rating, territory and whether answered; sort by newest, oldest, highest or lowest |
| `list_app_store_versions` | `GET /v1/apps/{id}/appStoreVersions?include=build` | `appVersionState` (in review, rejected, ready for distribution…), release type, build |
| `list_review_submissions` | `GET /v1/reviewSubmissions?filter[app]` | Submission state and the versions in it |
| `add_beta_tester` | `POST /v1/betaTesters` (a new email; Apple sends an invitation email) or `POST /v1/betaGroups/{id}/relationships/betaTesters` | Asks first |
| `remove_beta_tester` | `DELETE /v1/betaGroups/{id}/relationships/betaTesters` | Asks first, destructive |
| `add_build_to_group` | `POST /v1/betaGroups/{id}/relationships/builds` | Asks first. External groups accept it after beta review approval |
| `reply_to_review` | `POST /v1/customerReviewResponses` | Asks first. Replaces an earlier reply if there is one |
| `submit_for_review` | Read the version → that app and platform's unsent submission (`READY_FOR_REVIEW`) or a new `POST /v1/reviewSubmissions` → `POST /v1/reviewSubmissionItems` → `PATCH …{submitted: true}` | Asks first. If a submission started in App Store Connect already holds that version (409), it is sent as is |

- Replies are flattened into resource IDs and attributes, and the next page is given as `nextCursor`, the `cursor` taken
  from Apple's `links.next`. Errors are Apple's `errors[].detail` and the HTTP status ("App Store Connect: There is no
  resource of type 'apps' with id '404' (HTTP 404)"), and IDs that cannot go into a path are refused before the request.
  Endpoints follow Apple's App Store Connect API OpenAPI spec (4.5.1).
- **Key roles** (Apple's "Role permissions", developer.apple.com/support/roles): submitting for review and distributing
  builds to external TestFlight groups work only for Account Holder, Admin and App Manager, and replying to reviews only
  for Account Holder, Admin and Customer Support. So the one role for which all five write tools work is Admin. With an
  App Manager key, only `reply_to_review` fails, with Apple's 403 text.

### The Mac's calendars, reminders and contacts

- iCloud offers no OAuth API for this data, so Yardlet uses what the Mac has synced (`MacDataStoring`,
  `MacEventKitStore`, `MacDataToolRunner`). The calendars are the iCloud and other accounts' calendars in the Calendar
  app. Calendars and reminders use EventKit (`requestFullAccessToEvents` and `requestFullAccessToReminders`, from macOS
  14), and contacts use Contacts.
- **Permission:** the three are turned on separately. When one is turned on (connected) and its permission is not
  decided yet, macOS asks once; if it is already allowed, macOS does not ask. If it was denied or a device policy blocks
  it, nothing is asked, and the reason shows: "macOS doesn't let Yardlet use Calendars. Turn Yardlet on in System
  Settings → Privacy & Security → Calendars, then try again." Tool calls only read the permission and never ask. If the
  permission is turned off later, calls return the same message.
- A build without usage descriptions in Info.plist (`swift run`) does not ask, because macOS ends an app that asks
  without one.
- **Tools:**
  - Apple Calendar: `list_calendars`, `list_events` (by default the next 7 days, all calendars or one, a word filter, up
    to 4 years), `search_events` (one year before and after), `get_event`, and `create_event`, `update_event` and
    `delete_event` (they ask first). Argument names are Google Calendar's (`summary`, `startTime`, `endTime`, `allDay`,
    `timeZone`, `calendarId`, `location`, `description`) plus `url`, `alertMinutes` and `span` (`thisEvent` or
    `futureEvents` for a recurring event). EventKit cannot invite attendees or answer invitations, so those arguments,
    `respond_to_event` and `suggest_time` are missing. One occurrence of a recurring event is named
    `<event ID>@<original start UTC>`. A time without an offset is read in the `timeZone` argument, or the Mac's time
    zone when there is none (`CalendarTime`).
  - Apple Reminders: `list_reminder_lists`, `list_reminders` (by default unfinished ones; by list, due range and words),
    `create_reminder` (a date only, or a date and time; priority none, low, medium or high = EventKit 0, 9, 5, 1),
    `complete_reminder` (undo with `completed: false`). The last two ask first.
  - Apple Contacts: `search_contacts` (name, email or phone number; with `@` it is an email, with 4 or more digits a
    phone number), `get_contact`. Read only. Contact notes are not read (that needs a separate entitlement).
- EventKit calls run off the main thread, and the store handles one at a time under a single lock.
- **App bundle:** `NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription` and
  `NSContactsUsageDescription` in Info.plist (English), and Korean in `ko.lproj/InfoPlist.strings`.
  `Packaging/Entitlements/Yardlet.entitlements` has the hardened runtime's
  `com.apple.security.personal-information.calendars` (reminders included) and
  `com.apple.security.personal-information.addressbook`. When a command that Yardlet started uses this data, macOS still
  asks in Yardlet's name. `DeveloperIDSigningTests` checks that each entitlement has usage descriptions in both
  languages.

### Xcode

- In Apple's MCP server (from Xcode 26.3), the stdio bridge `mcpbridge` connects to the tool service of a running Xcode.
  Yardlet starts `mcpbridge` as its own child process and exchanges JSON-RPC with it (`XcodeBridge`, `MCPStdioClient`).
  So Xcode asks Yardlet alone for access, not each harness.
- **Finding it (`XcodeBridge.locate`):** looks for `Contents/Developer/usr/bin/mcpbridge` in `DEVELOPER_DIR`, the folder
  that `/var/db/xcode_select_link` points to, then `/Applications/Xcode.app` and `Xcode-beta.app`, in that order. It
  only reads paths, because running `xcrun` or `xcode-select` on a Mac without the developer tools brings up an install
  prompt.
- **When the bridge starts:** only when the person clicks "Connect" (which reads the tool list) or "Reload tools", and
  when an Xcode tool is called. It does not start when the app or a task starts (the tool list is the one kept in
  `connectors.json`), and the list is not read again every 12 hours. This is so that these alone never launch Xcode.
  Once started, the bridge stays until Yardlet quits or the connector is removed, and if the bridge ends, the next call
  starts it once more. When Yardlet quits, standard input closes and the bridge ends too.
- **Client:** line-based JSON-RPC, replies matched by request ID for concurrent calls, the server's `ping` answered and
  other server requests refused, and `notifications/cancelled` for a cancelled call. Lines are split only on the newline
  byte (so U+2028 inside a JSON string does not split one). Builds and tests take minutes, so calls have no time limit
  of their own and follow the harness's tool time limit. The last line the bridge left on standard error as it ended
  becomes the error ("Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model Context
  Protocol…", "No running Xcode found and could not launch one automatically.").
- **Conditions shown:** the Add connector tile says that a project must be open in Xcode, and the settings row shows the
  version and condition, as in "Xcode 27.1 · while it's open with a project". On failure, the reason shows with "Open
  Xcode with a project, and in Xcode Settings → Intelligence let other agents use Xcode's tools."
- **Import suggestion:** when harness settings have `xcrun mcpbridge`, Xcode appears in "You use these elsewhere"
  (`packages: ["mcpbridge"]`). A stdio Xcode server that a harness loads on its own has no address, so it is not subject
  to the stand-in and duplicate exclusion of the "Harnesses' own servers" section. So one task can get both the
  harness-side Xcode and the Yardlet-side Xcode.

### When the harness asks

- Tools that ask (`LocalConnectorService.approvalRequiredTools`): App Store Connect `add_beta_tester`,
  `remove_beta_tester`, `add_build_to_group`, `reply_to_review` and `submit_for_review`; Apple Calendar `create_event`,
  `update_event` and `delete_event`; Apple Reminders `create_reminder` and `complete_reminder`. Apple Contacts only
  reads. Xcode has no tools that Yardlet marks as asking.
- Claude Code: as with Google, connector tools are not in the allow list, so the CLI asks on every call. The request
  cards for the writes above use Yardlet's text and have no "Always allow" (`AppleToolApproval`): inviting a tester
  (saying Apple sends an invitation email) and removing one, distributing a build (saying the group's testers can
  install it), replying to a review (saying it shows on the App Store and replaces an earlier reply, with the first
  1,200 characters of the reply), submitting for review, creating, changing and deleting events in this Mac's calendars,
  and adding, completing and un-completing reminders. Xcode tools get the CLI's usual card.
- Codex: follows the annotations. All writes have `readOnlyHint: false` and `openWorldHint: true` (because they sync to
  the account's server or become public), and deleting an event and removing a tester have `destructiveHint: true`.
  Xcode tools carry the annotations the Xcode server gave, as they are.
- ACP: that harness's MCP approval, as is.

### Turning off and removing

- Turn one off for a task with the per-task switch, and remove it with the settings row's `…` → Remove. Remove deletes
  the record and the Keychain item (the App Store Connect key) and ends Xcode's `mcpbridge`. Nothing is written to
  harness settings files.
- macOS permissions (Yardlet's entry under System Settings → Privacy & Security) stay after removal, like Google scopes.
  Yardlet does not take permissions back, so the person turns them off in System Settings (row `…` → "Open Privacy &
  Security…").

### What the person does

- **App Store Connect** (a team key; the Admin role is recommended):
  1. appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API → Team Keys → "Generate API
     Key" (or +). Only Account Holder and Admin see it.
  2. Name (for example "Yardlet"), and access **Admin** (App Manager if you do not need review replies). Generate.
  3. "Download API Key" in the new key's row (works only once) → `AuthKey_<key ID>.p8` appears in the Downloads folder.
     Copy the issuer ID above the key list.
  4. Yardlet Settings → Connectors → Add connector → App Store Connect "Set up…" under "Paste a key or token" → Team key
     → "Choose .p8 File…" (the key ID is filled in from the file name) → paste the issuer ID → "Connect" → choose
     whether to move the key file to the Trash.
  - For an individual key, instead of steps 1 and 2: in App Store Connect, your profile → Individual API Key → "Generate
    API Key" (without permission, an Admin has to grant the "Generate Individual API Keys" permission). In step 4,
    choose "Individual key" and leave the issuer ID out.
- **The Mac's calendars, reminders and contacts:** Add connector → Apple Calendar (or Apple Reminders, Apple Contacts)
  "Connect" under "Connect in one click" → "Allow" in the macOS dialog (once for each of the three). To turn one off
  later, turn Yardlet off in System Settings → Privacy & Security → Calendars (Reminders, Contacts).
- **Xcode:** in Xcode → Settings → Intelligence → Model Context Protocol, turn on letting outside agents use Xcode's
  tools. Open a project. Add connector → Xcode "Connect" under "Connect in one click" → allow it when Xcode asks about
  Yardlet's access.
- After that, Claude Code tasks see the tools from their next turn, and tasks in other harnesses when they next start or
  resume (the "Tool lists of running tasks" section).

### Not included

- App Store Connect: certificates, profiles, sales reports, notarization, editing metadata and screenshots, phased
  release, submitting for beta review and diagnostics other than crash logs.
- Mac: adding attachments, attendees or recurrence rules to events, editing and deleting reminders, writing contacts and
  reading their notes, and the data of the Notes and Messages apps.
- Xcode: the Yardlet side does not stand in for a stdio Xcode server that a harness loads on its own (see "Xcode"
  above).

## 11. Slack

The Slack MCP server (`https://mcp.slack.com/mcp`) has no dynamic registration and accepts only apps published in the
Slack Marketplace and internal apps of the workspace. So, unlike Google, no app can go into the build, and each
workspace makes one app from Yardlet's manifest.

- **Manifest (`SlackAppManifest`):** name "Yardlet", `oauth_config.redirect_urls` = `http://127.0.0.1:47823/callback`,
  `oauth_config.scopes.user` = the 30 user scopes the server lists (no bot scopes; a desktop redirect cannot take bot
  scopes), `oauth_config.pkce_enabled: true`, `settings.is_mcp_enabled: true`. Turning MCP on is part of the manifest,
  so there is no separate step for it.
- **Why PKCE is on:** Slack requires HTTPS redirects, and accepts a loopback http redirect only as the desktop redirect
  of an app with PKCE on. A PKCE app sends no secret in the token exchange, so the only value the person copies is the
  client ID. Once PKCE is on, Slack does not let it be turned off, and a PKCE app's refresh tokens expire after 30 days
  (refreshes keep it going while it is used; after more than 30 days without use, sign in again). For an existing app
  with PKCE off, a secret entered in the secret field (folded) is sent with `client_secret_post`.
- **Create link:** `https://api.slack.com/apps?new_app=1&manifest_json=<JSON>`. The JSON is compacted with sorted keys,
  and every character outside the RFC 3986 unreserved set is percent-encoded (`&`, `=`, `+`, `#`, `/`, `:`, quotes and
  parentheses).

What the person does:

1. Settings → Connectors → Slack under "Set up in one go" → **Create in Slack** (a Slack page with the manifest filled
   in) → choose the workspace → Next → create and install.
2. In the new app, Basic Information → App Credentials → copy the **Client ID** → paste it into Yardlet's field (the
   `digits.digits` format is checked).
3. **Sign in to Slack** → allow Yardlet in the browser (if the workspace requires admin approval, request approval).

## 12. GitHub sign-in

GitHub's remote MCP server (`https://api.githubcopilot.com/mcp/`) has no dynamic registration, so only hosts with a
registered OAuth app can offer a sign-in button. Yardlet signs in with the device flow of a GitHub OAuth app.

- **App:** the client ID of a GitHub OAuth app (Redirect URI `http://127.0.0.1/callback`, **Enable Device Flow** on) is
  in `YardletGitHubOAuthClientID` of `Packaging/Info.plist`. A client ID is a public value and the device flow needs no
  secret, so the build holds no secrets. To build with your own app, change this value.
- **Flow (`GitHubDeviceSignIn`):** `POST github.com/login/device/code` (`client_id`, `scope=repo read:org workflow`,
  `Accept: application/json`) → the code (shaped like `WDJB-MJHT`) goes on the clipboard and shows in the connector row,
  and `github.com/login/device` opens in the default browser → `POST github.com/login/oauth/access_token`
  (`grant_type=urn:ietf:params:oauth:grant-type:device_code`) every `interval` seconds. `authorization_pending`
  continues, and `slow_down` changes the interval to the value GitHub gave. `access_denied` (cancel on GitHub's page)
  ends quietly, like Yardlet's cancel, and `expired_token` and `device_flow_disabled` end with a reason. When the code
  expires (15 minutes), Yardlet ends it on its side too.
- **Token:** OAuth app user tokens have no expiry and no refresh token, so only the access token is kept in Keychain. If
  the app is revoked on GitHub, the server refuses and the connector becomes "Needs sign-in".
- **When it is used:** for the GitHub entry, when the build has a client ID and there is neither a pasted token nor your
  own OAuth client (`signsInOnGitHub`). A connector already connected with a token stays as it is (to change it, remove
  it and add it again). While waiting, the row shows "Paste this code on GitHub's page: …" and a copy button.
- In a build without device code sign-in, put a personal access token into GitHub under "Paste a key or token", or after
  adding it, put a GitHub OAuth app (callback `http://127.0.0.1:47823/callback`) into the row's `…` → "Use an OAuth
  client of your own…".

## 13. Icons

- **Order (`ConnectorIconSources`):** the icons that connector's MCP server gave in `serverInfo.icons` of `initialize`
  (`https` on the same registrable domain as the server address, or `data:image/`; a light UI takes light → no theme →
  dark, a dark UI the reverse, and the largest in each theme) → the directory entry's `iconURL` (the service's own site)
  → the symbol or first letter. Other companies' favicon services and icons on sites other than the server's are not
  used. The app does not ship service logos.
- **Storing server icons:** when connecting and when a tool list older than 12 hours is read again, they go into
  `record.serverIcons`. A harness's own server may have no address, so its directory entry is found by name
  (`ConnectorPreset.preset(forServerNamed:)`) and that entry's icon is used.
- **Directory icons (`ConnectorPreset.iconAddresses`):** among each service homepage's
  `<link rel=icon|apple-touch-icon>` and the root's `apple-touch-icon.png` and `favicon.ico`, the ones on that service's
  domain and 32 px or larger. The company's static host that the homepage links directly, and the places the site
  redirects to, are followed as they are. Google services use Google's own images at
  `www.gstatic.com/images/branding/product/`, and App Store Connect uses the image on Apple's developer site
  (`developer.apple.com/assets/elements/icons/app-store-connect/`). Services without a usable icon (only 16 px, or only
  on another company's host) keep the symbol.
- **Apps on this Mac:** the directory icons of Apple Calendar, Apple Reminders, Apple Contacts and Xcode are those apps'
  `file://` addresses (`/System/Applications/Calendar.app` and others, `/Applications/Xcode.app`), and
  `ConnectorIconStore` draws the icon macOS gives that app (`NSWorkspace.icon(forFile:)`). It does not use the network,
  and without the app it is the symbol.
- **Fetching and cache (`ConnectorIconStore`):** an ephemeral `URLSession` without cookies, URL cache or credential
  storage fetches `https` only, within 15 seconds, up to 1 MB and only images that `NSImage` reads (PNG, ICO, SVG,
  JPEG). They are kept at `~/Library/Caches/<bundle ID>/ConnectorIcons/<FNV-1a 64>` and read from disk from the next
  launch. On failure, a marker is kept and the icon is not asked for again for a day. Clearing the cache fetches them
  again (nothing is written to the settings file). The app store in test processes does not use the network.
- **Drawing (`ConnectorIcon`):** at 20 pt or more, the image at 2/3 of the box's size in a pale box; in tool rows (16
  pt), the image only. Before fetching and on failure, the symbol or first letter.

## 14. Security and limits

- Another process of the same user that gets a task token for `yardlet-mcp` can call connector tools too. This is the
  same boundary as for the browser tools ([AGENT_BROWSER_TOOLS](AGENT_BROWSER_TOOLS.md) section 6).
- Tool approval belongs to the harness. Yardlet does not ask on its own. Only Claude Code's request cards for Google and
  Apple writes show Yardlet's text and leave out "Always allow" (the "Google" section and the "Apple" section).
- Content read through a connector goes through that task's harness to its provider. The same goes for data from the
  Mac's calendars, reminders and contacts and from App Store Connect. Yardlet does not write the bodies, requests and
  responses it gets from services to the log.
- The App Store Connect API key is only in Keychain; Yardlet makes 15-minute tokens with it and sends them to Apple.
  What an agent can do with the key is set by the key's type and role (the "Apple" section).
- The Browserbase key goes in the request address, as Browserbase specifies (it may stay in server logs). It is not in
  Yardlet's files, UI or error text.
- Not supported: the old HTTP+SSE transport (2024-11-05), Client ID Metadata Document (Yardlet has no https document
  address), resources and prompts, requests the server sends inside a stream (elicitation, sampling, roots), showing
  progress notifications, blocking individual tools and `notifications/tools/list_changed` sent by connector servers
  (remote MCP) themselves (server lists are read again when connecting and every 12 hours).
- Program connectors run someone else's code with the person's access; macOS gives them no sandbox from Yardlet. The
  person sees the exact command before it runs and runs it with one button; Yardlet passes only a small environment,
  keeps values in Keychain, pins registry versions, refuses Docker mounts, devices, privileges and host networking, and
  runs nothing a registry or another app's settings say on their own (the "Programs on this Mac" section). A remote
  server is still the simpler choice where a service has one, and the list shows remotes first.
- Registry text is someone else's: it is shown as plain text and never reaches a model (the "Registries" section).
- The loopback listener, Keychain, opening the browser, SHA-256, App Store Connect's ES256 signing (CryptoKit), EventKit
  and Contacts, and the addresses of the privacy panes in System Settings belong to the macOS platform layer. Windows
  needs its own Credential Manager store and loopback listener under the same contract, and has no Mac data or Xcode
  connectors.

## 15. Code locations

| Location | Contents | Layer |
|---|---|---|
| `Sources/NativeHarnessClient/Connectors/ConnectorModels.swift` | Records, credentials (including the `client` and `signingKey` kinds), the store contract, naming rules (`ConnectorToolNaming`), services inside the app (`LocalConnectorService`: the three Google and five Apple services) | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorDirectory.swift` | The directory (`ConnectorPreset`), import suggestions, task state (`ConnectorTaskState`, `ConnectorTaskScope`), tool row labels | engine |
| `Sources/NativeHarnessClient/Connectors/NativeMCPConfigs.swift` | Reading harnesses' own settings (Claude `.claude.json` and `.mcp.json`, Codex `config.toml`, Antigravity `mcp_config.json`) and other apps' (`NativeMCPApp`: the Claude app, Cursor, VS Code), the servers a task loads on its own, one program's launch (`NativeMCPLaunch`) | engine |
| `Sources/NativeHarnessClient/Connectors/MCPRegistry.swift`, `MCPRegistryDirectory.swift` | Reading and checking registry answers (`MCPRegistryFormat`, `MCPRegistryCheck`), what connecting asks (`Reach`), order and merging, the registry client, what Add connector shows | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorProgram.swift` | Program connectors: the record's `ConnectorProgram`, the Keychain `ConnectorProgramSpec`, registry packages as commands, finding the program, its environment, the page's draft (`ConnectorProgramDraft`) | engine |
| `Sources/NativeHarnessClient/Connectors/MCPHTTPClient.swift` | Streamable HTTP client, `WWW-Authenticate` parsing, event stream, key in the address | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorOAuth.swift` | Discovery, dynamic registration, your own client, authorization URL, token exchange and refresh, PKCE | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorCenter.swift` | The connector list, connecting and sign-in, the per-task switch, standing in for harness servers (`withYardletStandIns`), tool lists and calls, per-session token refresh (`ConnectorSession`), the Google app, accounts and sign-in, adding and connecting Apple services (`isAvailable`, `addLocal`, `addAppStoreConnectKey`), list change notification (`onToolsChanged`) | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleOAuth.swift` | Google endpoints, the app in the build (`BuiltInApp`), the Keychain item ID of the Google app, authorization parameters, scope checks | engine |
| `Sources/NativeHarnessClient/Connectors/OAuthAPISession.swift` | One account's bearer token for a REST API Yardlet calls itself (Google's, Microsoft Graph): refresh a minute before expiry and once after a 401, one at a time | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorToolSupport.swift` | Argument reading (`ConnectorToolArguments`) and schema pieces (`ConnectorToolSchema`) shared by Yardlet's own servers | engine |
| `Sources/NativeHarnessClient/Connectors/GmailToolCatalog.swift`, `GmailAPI.swift`, `GmailToolRunner.swift` | Gmail tool definitions, annotations and tools that ask; REST calls, reading messages (charset, HTML→text) and building MIME; requests and responses per tool | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleREST.swift` | REST client of the Google APIs other than Gmail (JSON, extra headers, downloads, multipart uploads) | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleCalendarToolCatalog.swift`, `GoogleCalendarToolRunner.swift` | Calendar tools, scopes and tools that ask; Calendar API v3 requests and responses; `CalendarTime` (time zones, free time) | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleDriveToolCatalog.swift`, `GoogleDriveToolRunner.swift` | Drive tools, scopes and tools that ask; Drive API v3 requests and responses (export, multipart); `DriveQuery` | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleEditorsToolCatalog.swift`, `GoogleEditorsToolRunner.swift` | The Drive connector's Docs, Sheets and Slides tools, tools that ask and APIs that must be enabled; Docs, Sheets and Slides API requests and responses; paging | engine |
| `Sources/NativeHarnessClient/Connectors/GoogleAnalyticsToolCatalog.swift`, `GoogleAnalyticsToolRunner.swift`, `GoogleAdsToolCatalog.swift`, `GoogleAdsToolRunner.swift` | Analytics and Ads tools and scopes; Admin, Data and Google Ads API requests, report rows, the `SELECT` check | engine |
| `Sources/NativeHarnessClient/Connectors/MicrosoftOAuth.swift`, `GraphAPI.swift` | Microsoft's endpoints per tenant, the app in the build, the person's app, permissions and grant checks, sign-in errors; the Graph client (headers, page links only into Graph, uploads) and shared shapes (`GraphShape`) | engine |
| `Sources/NativeHarnessClient/Connectors/OutlookMailToolCatalog.swift`, `OutlookMailToolRunner.swift`, `OutlookCalendarToolCatalog.swift`, `OutlookCalendarToolRunner.swift`, `OneDriveToolCatalog.swift`, `OneDriveToolRunner.swift`, `TeamsToolCatalog.swift`, `TeamsToolRunner.swift` | The Microsoft 365 tools, permissions and tools that ask; Graph requests and answers | engine |
| `Sources/NativeHarnessClient/Connectors/AppStoreConnectAPI.swift`, `AppStoreConnectToolCatalog.swift`, `AppStoreConnectToolRunner.swift` | `.p8` keys and ES256 tokens (the `ES256Signing` contract), the key session (a new token after a 401), JSON:API requests, the 14 tools and those that ask | engine |
| `Sources/NativeHarnessClient/Connectors/MacDataStore.swift`, `MacDataToolCatalog.swift`, `MacDataToolRunner.swift` | The Mac data store contract (`MacDataStoring`), permission states and error text; calendar, reminder and contact tools and running them | engine |
| `Sources/NativeHarnessClient/Connectors/MCPStdioClient.swift`, `XcodeBridge.swift` | stdio MCP client (matching request IDs, cancellation, the reason from standard error), the child process channel, finding `mcpbridge` and the Xcode version | engine |
| `Sources/NativeHarnessClient/Connectors/SlackAppManifest.swift` | The Slack app manifest and its create link | engine |
| `Sources/NativeHarnessClient/Connectors/GitHubDeviceSignIn.swift` | GitHub device code sign-in, the client ID in Info.plist | engine |
| `Sources/NativeHarnessClient/Connectors/ConnectorIcons.swift` | `MCPServerIcon` (`serverInfo.icons`), icon source order (`ConnectorIconSources`), own-site check (`ConnectorIconSite`), directory icon addresses | engine |
| `Sources/NativeHarnessClient/AgentTools/AgentToolBroker.swift` | `tools/list` and the connector call path, per-task scope, injection conditions, `tools/watch` | engine |
| `Sources/NativeHarnessClient/AgentTools/AgentToolInjection.swift` | Injection documents, the `deniedMcpServers` setting, `ClaudeAIConnectorPreference` | engine |
| `Sources/NativeHarnessClient/AgentTools/GmailToolApproval.swift`, `GoogleToolApproval.swift`, `MicrosoftToolApproval.swift`, `AppleToolApproval.swift` | Text of Claude Code request cards for Gmail, Calendar and Drive writes (Docs, Sheets and Slides included), for Outlook, OneDrive and Teams writes, and for App Store Connect and Mac calendar and reminder writes | engine |
| `Sources/YardletAgentTools/MCPServer.swift` | `listChanged: true`, the list the client got (`MCPToolListing`), watching the list and `notifications/tools/list_changed` (`watchToolList`) | engine |
| `Sources/NativeHarnessClient/Adapters/Claude/ClaudeProcessTransport.swift` | `ENABLE_CLAUDEAI_MCP_SERVERS=false` | engine |
| `Sources/NativeHarnessClient/Presentation/ConnectorSetupAssistant.swift` | "Set up in one go" step state, console links, values to copy, field checks | presentation |
| `Sources/NativeHarnessClient/Platform/macOS/Connectors/` | Keychain store, loopback listener (Network.framework, fixed port choice), opening the browser, SHA-256, icon fetching and cache (`ConnectorIconStore`, including icons of apps on this Mac), the EventKit and Contacts implementation (`MacEventKitStore`; it does not ask without usage descriptions; addresses of the privacy panes in System Settings), CryptoKit ES256 (`MacES256Signer`) | macOS |
| `Sources/NativeHarnessClient/Views/AppShell/ConnectorSettingsView.swift` | Settings → Connectors, the one-word state (`ConnectorSettingsState`), the "Set up in one go" cards | views |
| `Sources/NativeHarnessClient/Views/AppShell/ConnectorAddSheet.swift` | The "Add connector" sheet, steps and links per service (`ConnectorSetupGuide`) | views |
| `Sources/NativeHarnessClient/Views/AppShell/ConnectorRegistryViews.swift` | "From MCP registries" (`ConnectorRegistrySection`) and a program's page (`ConnectorProgramPage`) | views |
| `Sources/NativeHarnessClient/Views/AppShell/GoogleSetupPage.swift`, `MicrosoftSetupPage.swift`, `SlackSetupPage.swift`, `ZoomSetupPage.swift`, `ServiceAccountList.swift`, `ConnectorSetupAssistantViews.swift` | Google, Microsoft 365, Slack and Zoom setup assistants (step rows, copy buttons, checked fields), and the account list with per-account service chips that Google and Microsoft share | views |
| `Sources/NativeHarnessClient/Views/AppShell/AppStoreConnectSetupPage.swift` | The App Store Connect page (steps, key type, choosing the `.p8`, ID fields, key list, the Trash question) | views |
| `Sources/NativeHarnessClient/Views/Composer/ComposerPlusMenu.swift` | Rows and keys of the composer "+" menu (`ComposerMenuList`), the "+" order (`ComposerPlusMenu`), the connector list (`ComposerConnectorsMenu`) | views |
| `Sources/NativeHarnessClient/Views/Composer/ComposerConnectorsMenu.swift`, `Presentation/Composer/ComposerConnectorList.swift` | The connector environment, `ConnectorIcon`, session rail rows, list state | views |

Tests:

| Location | Contents |
|---|---|
| `Tests/NativeHarnessClientTests/ConnectorTests.swift` | The whole flow with fake authorization and MCP servers, names, the broker, loopback, refresh (retrying temporary failures, refresh token rotation, refresh by another copy), Keychain (opt-in `NHC_KEYCHAIN_LIVE=1`) |
| `Tests/NativeHarnessClientTests/ConnectorDirectoryTests.swift` | The directory, discovery with real metadata shapes, your own client, public clients and the key in the address, the per-task switch, duplicate exclusion and standing in for Claude harness servers (`--settings`), settings parsing (fake values), import, the claude.ai environment, injection documents, tool rows |
| `Tests/NativeHarnessClientTests/ConnectorLiveToolsTests.swift` | `list_changed` and list refresh with a fake MCP client, `tools/watch` over the socket, per-task changes in a real `ConnectorCenter`, clients that re-read and clients that do not, notification at the end of a turn, per-harness text |
| `Tests/NativeHarnessClientTests/GmailConnectorTests.swift`, `GoogleCalendarDriveConnectorTests.swift`, `GoogleBuiltInAppTests.swift`, `GoogleAnalyticsAdsConnectorTests.swift` | With a fake Google (`FakeGoogle`, `FakeGoogleWorkspace`, `FakeAnalyticsAds`): sign-in, scopes, accounts, and the requests and asking for each tool; the app in the build; Analytics reports and Ads reading only |
| `Tests/NativeHarnessClientTests/MicrosoftConnectorTests.swift` | With a fake identity platform and Graph (`FakeMicrosoft`): the public-client sign-in, a tenant of the person's app, rotated refresh tokens, the requests of mail, calendar, OneDrive and Teams tools, and a request card |
| `Tests/NativeHarnessClientTests/AppleConnectorTests.swift` | The whole flow with a fake App Store Connect (checking the token signature on every request), a fake Mac store and a fake `mcpbridge`: team key and individual key tokens, the key only in Keychain, the request and reply for each tool, refused keys, asking only for writes and the card text, Mac permissions and calendars, reminders and contacts, finding, connecting, restarting and removing Xcode, stdio with a real shell process |
| `Tests/NativeHarnessClientTests/GitHubDeviceSignInTests.swift` | Device code request, waiting, refusal and expiry, sending it to MCP as a bearer token |
| `Tests/NativeHarnessClientTests/MCPRegistryTests.swift` | Recorded registry answers (`Fixtures/mcp-registry-*.json`), checks on someone else's data, order, the client's requests, commands from packages, program connectors with a fake stdio server (keys only in Keychain, a harness's own copy, removal), a key in a named header, other apps' settings and one program's launch |
| `Tests/NativeHarnessClientTests/ConnectorRegistryRenderingTests.swift` | Draws the registry list, a search, a program's page and programs offered from other apps under `.build/connector-registry-qa/`, light and dark |
| `Tests/NativeHarnessClientTests/ConnectorSetupAssistantTests.swift` | The Slack manifest and link encoding, Google and Slack step state, field checks, suggestions read by name only |
| `Tests/NativeHarnessClientTests/ConnectorIconTests.swift` | Icon order, themes and source limits, fetching, cache and waiting after a failure (opt-in `YARDLET_CONNECTOR_ICONS_LIVE=1` fetches from the real service sites and draws them) |
| `Tests/NativeHarnessClientTests/ConnectorsRenderingTests.swift`, `ConnectorsEasyQARenderingTests.swift`, `PlusConnectorsQARenderingTests.swift`, `GmailSetupRenderingTests.swift`, `AppleConnectorsRenderingTests.swift`, `MicrosoftZoomRenderingTests.swift` | Draws settings, the add sheet, the assistants, the composer list and the App Store Connect page under `.build/`, in light and dark. The Apple connection flow runs with accessibility presses in a transparent off-screen window |

## 16. QA (without a model turn)

`scripts/connector-qa/`:

- `mock-connector-server.py`: an authorization server + MCP server on 127.0.0.1. It checks the registered redirect URI,
  PKCE verification, resource, bearer token and MCP session like a real server, and approves authorization at once and
  redirects back. It answers `tools/call` with an event stream that starts with a progress notification.
- `run-check.sh <QA app> <output folder>`: starts the mock server, launches the QA bundle with a temporary home and the
  settings fixture (`connectors`), and has it add and connect a connector through `YARDLET_CONNECTOR_QA_ADD`.
  `YARDLET_CONNECTOR_QA_FOLLOW_SIGN_IN=1` makes URLSession follow the authorization URL's redirects instead of a
  browser, and `YARDLET_CONNECTOR_QA_MEMORY_CREDENTIALS=1` keeps credentials in memory in a temporary home without a
  login keychain. Then `drive-mcp.py` starts `yardlet-mcp` like a harness and checks the list and calls.
  `run-check.sh finish …` quits the app, launches it again with `YARDLET_CONNECTOR_QA_REMOVE_ALL=1` to remove the
  connectors, and then stops the server.
- `drive-codex.py`: puts the server into the Codex app-server of an empty temporary `CODEX_HOME` through the `config` of
  an ephemeral `thread/start`, and sends `mcpServerStatus/list` and `mcpServer/tool/call`.

Real service sign-ins and model turns are not part of this QA. Unit tests use fake authorization, MCP and Google servers
and real metadata shapes, and rendering tests draw without a screen.

## 17. Microsoft 365

Outlook Mail, Outlook Calendar, OneDrive and Microsoft Teams are servers that Yardlet runs inside the app on Microsoft
Graph v1.0 (`outlookMail`, `outlookCalendar`, `oneDrive` and `teams` of `LocalConnectorService`, `accountProvider`
`.microsoft`). Like Google's, they go into the tasks of every harness and account through the one `yardlet` MCP server,
tokens stay in Yardlet, and the per-task switch, tool row labels and the Antigravity exclusion work as for other
connectors. Each Microsoft account signs in once for the services turned on for it, with the same account machinery as
Google's (the "Google" section, "Accounts and services").

### App and sign-in

- **The app** is a public client of the Microsoft identity platform: authorization code with PKCE `S256`, no secret, and
  the fixed loopback `http://127.0.0.1:47823/callback`. A build may carry Yardlet's own registration:
  `scripts/build-app.sh` reads `YARDLET_MICROSOFT_CLIENT_ID` or `Packaging/MicrosoftOAuthClient.json`
  (`{"client_id": …}`, kept out of git; an example is `Packaging/MicrosoftOAuthClient.example.json`) and writes
  `YardletMicrosoftOAuthClientID` into Info.plist (`MicrosoftOAuth.BuiltInApp`). A person may save an app of their own
  (client ID and an optional directory), which takes precedence; it is kept in `connectors.json` because a public client
  has no secret. Each account's Keychain item carries the client and token endpoint it signed in with.
- **Endpoints:** `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize` and `…/token`, where the tenant is
  `common` (work, school and personal accounts) unless the person's app names its directory; Graph at
  `https://graph.microsoft.com/v1.0/`. No discovery request and no dynamic registration.
- **One sign-in** asks for `offline_access`, `User.Read` and the permissions of the services turned on, in directory
  order, with `prompt=select_account` for a new account and `login_hint=<address>` for a sign-in again. A missing refresh
  token is a failure. The identity platform rotates refresh tokens on every use; the new one replaces the stored one,
  and each refresh names the permissions again (`ConnectorCredential.refreshScope`).
- **Granted permissions:** the token answer lists Graph permissions with or without `https://graph.microsoft.com/`, in
  any case; both are read (`MicrosoftOAuth.grantedServices`). A service whose permissions are missing gets "Needs
  sign-in" with a reason, as Google's partial grants do.
- **Account address:** Graph `GET me?$select=mail,userPrincipalName`: `mail`, else the sign-in name (a personal account
  may have no `mail`). A different account on a reconnect, cancelling, merging the same account, and naming slugs
  (`outlook`, `outlook_calendar`, `onedrive`, `teams`; a later account adds its address's first part) are as for Google.
- **Consent:** none of the permissions needs an administrator by Graph's permission table, but an organization's
  consent policy can still require one; Microsoft's default for a new tenant leaves mail, calendar and chat permissions
  out of user consent. The page says to ask the administrator to grant consent, or to register the app in the
  organization. Personal accounts have Outlook and OneDrive; Graph has no Teams for them, so a new account starts without
  Teams.

### Permissions

| Service | Permissions | Why |
|---|---|---|
| All | `offline_access`, `User.Read` | Stay signed in; read whose account it is |
| Outlook Mail | `Mail.ReadWrite`, `Mail.Send` | Search and read, drafts, read state, flags, categories and moving; sending |
| Outlook Calendar | `Calendars.ReadWrite` | Read, create, change, delete and answer events; free and busy times |
| OneDrive | `Files.ReadWrite` | Read every file; create new files and folders (see below) |
| Microsoft Teams | `Chat.Read`, `ChatMessage.Send`, `Team.ReadBasic.All`, `Channel.ReadBasic.All`, `ChannelMessage.Send` | Read chats; send to chats and channels; list teams and channels |

- Graph has no OneDrive permission that writes only new files without a file picker, so the code keeps the writes to
  new files and folders: an upload's `@microsoft.graph.conflictBehavior` is `fail` (default) or `rename`, never
  `replace` (Graph's default for a PUT), and there is no delete, move or sharing.
- Reading channel messages needs `ChannelMessage.Read.All`, which only an administrator can grant, so it is left out.

### Tools

Names and arguments follow Yardlet's Gmail, Google Calendar and Google Drive tools where they mean the same, so a model
uses both providers alike. Graph's list answers become `nextPageToken`, which is the page link Graph gave; a link that
does not point into the Graph base is refused before any request, so the token goes nowhere else. Errors show Graph's
`error.message` and the HTTP status.

Outlook Mail (`OutlookMailToolCatalog`, `OutlookMailToolRunner`):

| Tool | Graph | Notes |
|---|---|---|
| `search_messages` | `GET me/messages` or `me/mailFolders/{id}/messages` | `query` as `$search` (KQL; Graph sorts by date and takes no `$orderby` with it), otherwise newest first; `folderId` (an ID or `inbox`, `archive`…), `unreadOnly`, 1–50 per page. No body |
| `get_message` | `GET me/messages/{id}` with attachments' names | `format` text (default, `Prefer: outlook.body-content-type="text"`) or html, 40,000 characters |
| `list_folders` | `GET me/mailFolders` or `…/childFolders` | |
| `create_draft` | `POST me/messages`, or `createReply`/`createReplyAll` | to, cc, bcc, subject, body or htmlBody, `replyToMessageId`, `replyAll` |
| `send_draft` | `POST me/messages/{id}/send` | |
| `send_message` | `POST me/sendMail` (kept in Sent Items), or `reply`/`replyAll` | A reply's text goes as `comment`, which keeps the quoted original |
| `update_message` | `PATCH me/messages/{id}`, `POST …/move` | `isRead`, `flag`, `categories`, `moveToFolderId`; moving gives a new ID |

Addresses with a comma, a line break or no `@` are refused before the request.

Outlook Calendar (`OutlookCalendarToolCatalog`, `OutlookCalendarToolRunner`):

| Tool | Graph | Notes |
|---|---|---|
| `list_calendars` | `GET me/calendars` | |
| `list_events` | `GET me/calendarView` or `me/calendars/{id}/calendarView` | By default the next 7 days, in start order, recurring events expanded |
| `get_event` | `GET me/events/{id}` | With the body as text |
| `suggest_time` | `POST me/calendar/getSchedule` | Everything but free counts as busy, then `CalendarTime.freeSlots` as for Google. A personal account has no `getSchedule`: its own events stand for its busy times, and the attendees come back in `unavailableCalendars` |
| `create_event` | `POST me/events` or `me/calendars/{id}/events` | `summary`, `startTime`, `endTime`, `timeZone`, `allDay`, `description`, `location`, `attendeeEmails`, `optionalAttendeeEmails`, `addTeamsMeeting`, `reminderMinutes`, `showAs`. Outlook invites the attendees |
| `update_event` | `PATCH me/events/{id}` (with a GET first when times or attendees change) | Moving only the start keeps the length; `addedAttendeeEmails`, `removedAttendeeEmails` |
| `delete_event` | `DELETE me/events/{id}` | For a meeting the account organizes, Outlook sends a cancellation |
| `respond_to_event` | `POST me/events/{id}/accept`, `decline` or `tentativelyAccept` | `responseStatus`, `responseComment`, `sendResponse` |

- Times: Graph is asked for and given times in UTC (`Prefer: outlook.timezone="UTC"`, `{dateTime, timeZone: "UTC"}`), so
  no Windows time zone name is needed. A time without an offset is read in `timeZone` or this Mac's zone, and answers
  give each time with that zone's offset. An all-day event is midnight UTC of its first day and of the day after its last,
  which Outlook keeps on those dates; answers give its first and last day.

OneDrive (`OneDriveToolCatalog`, `OneDriveToolRunner`):

| Tool | Graph | Notes |
|---|---|---|
| `search_files` | `GET me/drive/root/search(q='…')` | Names, metadata and content, including files shared with the account |
| `list_folder` | `GET me/drive/root/children` or `me/drive/items/{id}/children` | |
| `get_file_metadata` | `GET me/drive/items/{id}` | Name, type, size, folder, link, last change |
| `read_file_content` | The item's `@microsoft.graph.downloadUrl` | Text files only (text types and common text extensions), 100,000 characters |
| `download_file_content` | The same address | base64, up to 5 MB |
| `upload_file` | `PUT me/drive/items/{parent}:/{name}:/content?@microsoft.graph.conflictBehavior=fail` | Text or base64, up to 4 MB; `rename` on request; names with `/ \ : * ? " < > |` are refused |
| `create_folder` | `POST me/drive/items/{parent}/children` | `fail` or `rename` |

- The download address is short-lived and carries its own authorization, so it is fetched without the account's token.
  `me/drive/recent` is not used: Microsoft stops it in November 2026.

Microsoft Teams (`TeamsToolCatalog`, `TeamsToolRunner`):

| Tool | Graph | Notes |
|---|---|---|
| `list_chats` | `GET me/chats?$expand=members` | Most recently active first within the page, with members' names |
| `list_chat_messages` | `GET chats/{id}/messages` | Newest first, HTML read as text, 8,000 characters each |
| `send_chat_message` | `POST chats/{id}/messages` | Text |
| `list_teams` | `GET me/joinedTeams` | |
| `list_channels` | `GET teams/{id}/channels` | |
| `send_channel_message` | `POST teams/{id}/channels/{id}/messages` or `…/messages/{id}/replies` | `subject` for a new post, `replyToMessageId` for a thread |

### When the harness asks

- Tools that ask (`LocalConnectorService.approvalRequiredTools`): Outlook Mail `send_draft`, `send_message` and
  `update_message`; Outlook Calendar `create_event`, `update_event`, `delete_event` and `respond_to_event`; OneDrive
  `upload_file` and `create_folder`; Teams `send_chat_message` and `send_channel_message`. Drafts are not asked about, as
  for Gmail.
- Claude Code: the request cards use Yardlet's text and have no "Always allow" (`MicrosoftToolApproval`): mail shows the
  recipients, subject and the first 1,200 characters of the body; a message change shows read state, flag, categories and
  where it moves; events show the title, time, invitees, a Teams link and what Outlook sends; OneDrive shows the name,
  folder and what happens when the name is taken; Teams shows the chat or the team and channel, and the message.
- Codex and ACP: as for Google, from the annotations (`destructiveHint` on `update_message`, `update_event` and
  `delete_event`).

### Turning off and removing

- Per task with the switch; per account with the service chips on the Microsoft page; Remove deletes the record, and the
  account's Keychain item goes with its last service. Yardlet does not revoke consent at Microsoft: a personal account
  removes Yardlet at account.live.com/consent/Manage, and an organization's administrator removes its consent in
  Microsoft Entra.

### Your own Microsoft app

Someone whose build has no Microsoft app, or whose organization admits only apps it registered, registers one in
Microsoft Entra. The Microsoft page opens the steps in order (`ConnectorSetupAssistant.microsoft`):

1. **App registrations → New registration** (entra.microsoft.com): name Yardlet; supported accounts "any organizational
   directory and personal Microsoft accounts", or only the organization's; no redirect yet.
2. **Manifest**: add `http://127.0.0.1:47823/callback` to `publicClient` → `redirectUris`, or in the older AAD Graph
   manifest `{ "url": "http://127.0.0.1:47823/callback", "type": "InstalledClient" }` to `replyUrlsWithType`, and save.
   Microsoft's redirect form does not take a `127.0.0.1` address (learn.microsoft.com/entra/identity-platform/reply-url),
   and a public client redirect makes the app a desktop client with no secret. Not as a web or single-page redirect:
   those need a secret or an `Origin` header.
3. **API permissions → Microsoft Graph → Delegated**: the permissions above. An administrator may grant consent for the
   organization here.
4. Paste the **Application (client) ID**, and for a single-organization app its **Directory (tenant) ID**, then Save.
5. Pick the services and **Sign in with Microsoft**.

### Not included

- Mail: attachments (reading their content, sending them), deleting, rules, shared mailboxes.
- Calendar: recurrence rules on create, shared calendars of other people, rooms.
- OneDrive: replacing or deleting files, sharing, SharePoint sites, reading Word, Excel, PowerPoint and PDF as text.
- Teams: reading channel messages (administrator consent), creating chats or teams, meeting transcripts.
