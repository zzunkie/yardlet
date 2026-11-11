# Yardlet relay

The relay connects a Mac running Yardlet to its phones when they are not on the same network. It is one
Cloudflare Worker with two Durable Object classes:

- `Room`, one per Mac. It forwards binary frames between the Mac's socket and up to 8 phone sockets the Mac
  has answered, besides a few still waiting for its first frame (docs/REMOTE_PROTOCOL.md §14.3). The frames
  are Noise messages that only the Mac and the phone can read; the relay keeps a room only in memory while its
  Mac is connected and stores none of them. It also sends the Mac's encrypted push notifications through FCM
  (Android) or APNs (iOS).
- `Account`, one per optional sign-in account (GitHub or Google). It keeps the account's Macs (name, room and
  public keys), sign-in token hashes and pending one-time codes. It never sees tasks or conversations.

The contract is [the remote protocol](../docs/REMOTE_PROTOCOL.md), §14 (relay and accounts), §11.2 (rooms) and
§16 (push). Logs never hold frame contents, push tokens, signatures or sign-in secrets.

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
```

## Check

```sh
npm test           # Vitest inside workerd (@cloudflare/vitest-plugin)
npm run typecheck
```

The tests fake FCM, APNs, Google's OAuth endpoints and GitHub; they make no network requests. Their credentials are
generated for each run.

CI runs both, after `npm ci`, for every change under `relay/` (`.github/workflows/relay.yml`).

## Deploy

Yardlet's own relay answers at `https://relay.yardlet.app`, a Custom Domain attached to the Worker in the
Cloudflare dashboard (the `yardlet.app` zone is on Cloudflare); `scripts/release.sh` builds it into releases.
Nothing here deploys it, and `wrangler.jsonc` names no route, so a deploy leaves the domain as it is (check the
Worker's Domains tab after one). To run your own:

1. A Cloudflare account. The free plan is enough: both classes use SQLite-backed Durable Objects.
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
