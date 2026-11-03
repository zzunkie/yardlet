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
   `scripts/build-app.sh`; the bundle carries it as `YardletRelayURL`.
