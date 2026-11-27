# Yardlet relay

The relay connects a Mac running Yardlet to its phones when they are not on the same network. It is one
Cloudflare Worker with three Durable Object classes:

- `Room`, one per Mac. It forwards binary frames between the Mac's socket and up to 8 phone sockets the Mac
  has answered, besides a few still waiting for its first frame (docs/REMOTE_PROTOCOL.md §14.3). The frames
  are Noise messages that only the Mac and the phone can read; the relay keeps a room's sockets only in memory while
  its Mac is connected and stores none of them. It also sends the Mac's encrypted push notifications through FCM
  (Android) or APNs (iOS), each to a push target a phone bound to that room, which the room keeps in its storage
  (docs/REMOTE_PROTOCOL.md §14.5).
- `Account`, one per optional sign-in account (GitHub or Google). It keeps the account's Macs (name, room and
  public keys), sign-in token hashes, pending one-time codes and short-lived enrollment grant hashes. It never sees tasks or conversations.
- `FeedbackSubmission`, one per feedback submission id. It remembers only whether that id is being sent or was
  sent, for about 7 days, so a retry never sends a second mail ("Feedback" below).

The same Worker answers `POST /v1/feedback`, which forwards what a person sends from the app's Feedback window
to the team's inbox by email. A second, small Worker in `edge/` serves the update feeds and the download address
("Edge Worker" below). Both write anonymous counts ("What is counted" below).

The contract is [the remote protocol](../docs/REMOTE_PROTOCOL.md), §14 (relay, accounts and push targets), §11.2
(rooms) and §16 (push). Logs never hold frame contents, push tokens, signatures or sign-in secrets.

## Feedback

`POST /v1/feedback` takes one submission from the app's Feedback window, which the person writes and sends
themselves, and forwards it once by email to the team's inbox through Cloudflare's `send_email` binding. Nothing
of it is stored or logged: the mail is the only copy.

```
Content-Type: application/json      (anything else: 415)
Body at most 16 KiB                 (larger, by Content-Length or as read: 413)
{
  "id": "<UUID, lowercase>",         the same for every retry of one submission
  "kind": "feedback" | "problem",
  "message": string, 1 to 4000 characters once trimmed,
  "replyTo": optional, an email address of at most 254 characters,
  "context": {
    "app": string ≤ 80, "surface": string ≤ 40,
    "macOS": optional string ≤ 80, "harness": optional string ≤ 40,
    "error": optional { "kind": string ≤ 60, "code": optional string ≤ 60 }
  }
}
```

Unknown fields, control characters in the context and malformed values answer 400 `{"status":"malformed"}`.
Otherwise the answer is 202 `{"status":"accepted"}` when the mail went out now or the same id already sent one,
409 `{"status":"inProgress"}` while the same id is being sent (the client retries later), 429
`{"status":"rateLimited"}` with `Retry-After`, 503 `{"status":"notConfigured"}` without the mail binding,
`FEEDBACK_FROM` or `FEEDBACK_TO`, and 503 `{"status":"unavailable"}` when the mail failed; a retry with the same
id then sends. Other methods answer 405.

The mail is plain UTF-8 text from `FEEDBACK_FROM` to `FEEDBACK_TO`: the message, then the kind and the context
fields, and nothing else. Its subject is "Yardlet feedback" or "Yardlet problem report" with the app version. A
`replyTo` that looks like an address becomes its `Reply-To`; there is no other way back to the sender.

Each submission id gets a `FeedbackSubmission` object, which marks it sending, then sent, and forgets it after
about 7 days (an alarm deletes the record); a failed mail clears the mark so a retry sends. Two Workers Rate
Limiting bindings allow 5 submissions a minute from one client address and 60 a minute in all. The client
address (`CF-Connecting-IP`) is used only as the limiter's key: the binding keeps its counters in memory at each
Cloudflare location and persists no key, and the relay neither stores nor logs the address.
`wrangler.jsonc` turns on no Workers Logs or Logpush; keep both off for the relay and the edge Worker, since
their request logs would record client addresses.

## What is counted

The relay and the edge Worker count a few events in one Workers Analytics Engine dataset, `yardlet_metrics`
(binding `METRICS`). A point holds the event name and coarse labels only, never an IP address, a room, an
account, a device, a token, a key, a push target or anything a frame or a feedback message holds. Without the
binding nothing is counted, and a failed write never fails a request (`src/metrics.ts`).

| Event | Labels | When |
| --- | --- | --- |
| `relay.host` | `ready` or `authFailed` | a Mac's socket authenticates, or fails to |
| `relay.client` | `open`, `noHost` or `full` | a phone or another Mac connects, or is turned away |
| `relay.close` | `host` or `client`, close code, `relay` or `peer` | a socket closes, and who closed it |
| `relay.push` | `fcm` or `apns`, `ok` or the error, `notify` or `offer` | a push is sent to FCM or APNs |
| `account.signUp`, `account.signIn` | `github` or `google` | a sign-in makes a new account, or signs in to one |
| `account.signInFailed` | provider (or `unknown`), error | a provider callback or a code exchange fails |
| `account.mac` | `added` or `removed` (amount in `double1`) | a Mac is registered to an account or leaves it |
| `account.deleted` | | an account is deleted |
| `update.check` | Yardlet version, `arm64` or `x86_64` | Sparkle reads an appcast (edge Worker) |
| `download` | channel, `arm64` or `x86_64`, `latest` or `pinned` | someone follows a download link (edge Worker) |

Analytics Engine keeps points for 3 months. `scripts/metrics.mjs` prints the last week's tables (or
`--days <n>`, `--json`) through the Analytics Engine SQL API:

```sh
CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… npm run metrics
```

The token needs only the "Account Analytics: Read" permission and is read from the environment; keep it out of
the repository. A weekly report job can run the same command.

To omit team or test devices from relay and account counts without putting IDs in the repository, set the optional
comma-separated Worker secrets `METRICS_EXCLUDE_ACCOUNTS` (32-character hashed account IDs) and
`METRICS_EXCLUDE_ROOMS` (32-character room IDs). When an excluded account reads its account or registers a Mac, each
of its rooms is also marked to omit relay counts automatically.

## Edge Worker

`edge/` is a second Worker, `yardlet-edge`, deployed on its own from that folder; it shares this folder's
toolchain, lock file, tests and CI, and the relay's counts dataset.

- Update feeds: routes on `yardlet.app/appcast.xml` (Apple silicon) and `yardlet.app/appcast-x86_64.xml` (Intel)
  pass each request on to the site unchanged, so Sparkle gets the same feed, headers and caching as before. A
  `GET` from Sparkle counts one `update.check` under the Yardlet version in its user agent
  (`Yardlet/<version> Sparkle/<version>`) and the architecture the file is for. Other user agents are not counted.
- Downloads: `https://dl.yardlet.app/<channel>/<arch>` (`arch` is `arm64` or `x86_64`) answers 302 to the disk
  image of the newest item in that architecture's appcast on GitHub Releases, or the latest release's page when
  the appcast cannot be read; `/<channel>/<arch>/<version>` answers with that version's image
  (`Yardlet-<version>.dmg` or `Yardlet-<version>-x86_64.dmg`, as `scripts/release.sh` names them), for links
  that must not move, such as a Homebrew cask's. `channel` says where the link is placed: `site`, `readme`,
  `homebrew`, `github` or `docs`; any other name still downloads and counts as `other`. `HEAD` requests and
  crawlers, link previews and scripted fetchers (by user agent) are redirected but not counted; Homebrew and
  `curl` count.

## Run locally

Node.js 22 or newer.

```sh
npm ci
npm run dev        # wrangler dev --local --port 8787, no Cloudflare login needed
```

The relay is then at `ws://127.0.0.1:8787` (health: `http://127.0.0.1:8787/v1/health`). Push and sign-in answer
`notConfigured` until their secrets are set; for local runs put them in `.dev.vars` (ignored by Git):

```sh
FCM_PROJECT_ID=your-firebase-project
FCM_SERVICE_ACCOUNT={"client_email":"…","private_key":"-----BEGIN PRIVATE KEY-----\n…"}
APNS_KEY="-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----"
APNS_KEY_ID=…
APNS_TEAM_ID=…
APNS_TOPIC=your.ios.bundle.id
GITHUB_CLIENT_ID=…
GITHUB_CLIENT_SECRET=…
GOOGLE_CLIENT_ID=…
GOOGLE_CLIENT_SECRET=…
AUTH_STATE_SECRET=…
PUBLIC_URL=http://127.0.0.1:8787
FEEDBACK_FROM=feedback@example.test
FEEDBACK_TO=team@example.test
```

Locally, Wrangler writes each feedback mail to a file and prints its path instead of sending it, and counts go
nowhere.

## Check

```sh
npm test           # Vitest inside workerd (@cloudflare/vitest-plugin)
npm run typecheck
```

The tests fake FCM, APNs, Google's OAuth endpoints, GitHub, the mail binding and the site; they make no network
requests. Their credentials are generated for each run. The edge Worker's tests (`edge/test/`) run in the same
`npm test`, against `edge/wrangler.jsonc`.

CI runs both, after `npm ci`, for every change under `relay/` (`.github/workflows/relay.yml`).

## Deploy

Yardlet's own relay answers at `https://relay.yardlet.app`, a Custom Domain attached to the Worker in the
Cloudflare dashboard (the `yardlet.app` zone is on Cloudflare); `scripts/release.sh` builds it into releases.
Nothing here deploys it, and `wrangler.jsonc` names no route, so a deploy leaves the domain as it is (check the
Worker's Domains tab after one). To run your own:

1. A Cloudflare account. The free plan is enough: all three classes use SQLite-backed Durable Objects.
2. `npx wrangler login`, then `npx wrangler deploy`. The Worker gets a `*.workers.dev` address; a custom domain
   is optional.
3. Push (optional): a Firebase project and a service account key allowed to send FCM messages.
   `npx wrangler secret put FCM_SERVICE_ACCOUNT` (the key's whole JSON) and `npx wrangler secret put FCM_PROJECT_ID`.
   For iOS, an APNs auth key (a `.p8` file from the Apple developer account's Keys page, with Apple Push Notifications
   service enabled): `npx wrangler secret put APNS_KEY < AuthKey_<key ID>.p8` (the file's whole text), then
   `APNS_KEY_ID` (the key's ID), `APNS_TEAM_ID` (the developer team's ID) and `APNS_TOPIC` (the iOS app's bundle ID).
   One key sends to both development and production builds; the phone says which one it is.
4. Accounts (optional):
   - A GitHub OAuth App and a Google OAuth client (web application), each with the callback
     `https://<relay>/v1/auth/<provider>/callback` (`github` or `google`).
   - Secrets `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and
     `AUTH_STATE_SECRET` (32 random bytes, for example `openssl rand -hex 32`).
   - `PUBLIC_URL`, the relay's https base such as `https://relay.example.test`: a secret
     (`npx wrangler secret put PUBLIC_URL`) keeps the address out of git, or `"vars"` in `wrangler.jsonc`.
     `npx wrangler deploy --secrets-file <file>` uploads secrets with the first deploy.
   - Next: Sign in with Apple and e-mail links are not implemented yet.
5. Put the relay's address on the first line of `Packaging/RelayURL` (or `YARDLET_RELAY_URL`) before
   `scripts/build-app.sh`; the bundle carries it as `YardletRelayURL`. Without either the bundle carries no
   relay and phones reach the Mac only directly. A Windows build gets the same address from the same places
   through `Windows/scripts/place-relay.ps1`, as a `YardletRelayURL` file beside its executable. A running app
   uses `YARDLET_REMOTE_RELAY_URL` from its environment, or else its `Yardlet.remote.relayURL` setting, before
   the relay its build carries.
6. A second, nearer address (optional). On a free-plan zone some networks reach the relay through a far
   Cloudflare location (Korean networks through Los Angeles or Hong Kong, for example), while a `*.pages.dev`
   address is served from the nearest one. `pages/` is a Pages project that hands every request to the Worker
   through a service binding, so both addresses reach the same rooms: after the Worker is deployed,
   `npx wrangler pages project create <name> --production-branch main --force` once (`--force` keeps it a Pages
   project, which gets the `*.pages.dev` address; without it Wrangler now deploys a Worker instead, from the nearest
   Wrangler configuration it finds), then
   `npx wrangler pages deploy pages/public --project-name <name>` from this folder (with `name` in
   `pages/wrangler.jsonc` set to the same project name and `service` to the Worker's name). Clients race this
   address against the main one, which stays the address for accounts and sign-in. Rooms are placed by the
   country of the request that first opens them (`src/placement.ts`), so a room lives near its Mac whichever
   address it came in through. For the Mac, put the address on the first line of `Packaging/RelayAlternateURL`
   (or `YARDLET_RELAY_ALTERNATE_URL`); the bundle carries it as `YardletRelayAlternateURL` (only beside a main
   address), and the Mac races it against the main address for its room (docs/REMOTE_PROTOCOL.md §14.2). A
   relay set in the environment or the setting takes its second address from the same place
   (`YARDLET_REMOTE_RELAY_ALTERNATE_URL`, `Yardlet.remote.relayAlternateURL`), never the built-in one's.
7. Feedback (optional). Steps for the account's owner, before the deploy that should start sending:
   - In the Cloudflare dashboard, turn on Email Routing for the zone the sender address will be in (for
     Yardlet, `yardlet.app`), and add the team inbox under Email Routing › Destination addresses. Cloudflare
     mails it a link; the address works as a recipient only once that link is followed.
   - `npx wrangler secret put FEEDBACK_FROM` (an address in that zone, for example `feedback@<zone>`; it does
     not need a mailbox) and `npx wrangler secret put FEEDBACK_TO` (the verified destination address). Neither is
     in git.
   - Deploy. Then send one submission from a development build, or with `curl`, and check it arrives once; send
     the same body again and check no second mail arrives.
8. Counts (optional). Workers Analytics Engine has to be enabled once for the account (Workers & Pages ›
   Analytics Engine in the dashboard); the `yardlet_metrics` dataset is made by the first write. For
   `scripts/metrics.mjs`, create an API token with only "Account Analytics: Read".
9. The edge Worker (optional). From `edge/`: `npx wrangler deploy`. Its `dl.yardlet.app` Custom Domain makes its
   own DNS record. The appcast routes run only while the zone's `yardlet.app` record is proxied (orange cloud):
   the site is on GitHub Pages, so proxy that record with SSL/TLS mode Full (strict), check that
   `https://yardlet.app/` and both appcasts still load and that `curl -A "Yardlet/0.11.16 Sparkle/2.10.1"
   https://yardlet.app/appcast.xml` returns the same feed as before, and only then point the site's, the
   README's and the cask's download links at `https://dl.yardlet.app/<channel>/<arch>`. Turning the routes off
   (or the record back to DNS only) returns everything to the site as it was; nothing in the app changes.
