import { env, exports } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { sha256, toBase64Url } from "../src/keys";
import { accountIdFor, signState } from "../src/oauth";
import { RELAY, macKey, type MacKey } from "./helpers";

const APP_REDIRECT = "yardlet-remote://auth";
const encoder = new TextEncoder();

function call(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(`${RELAY}${path}`, { redirect: "manual", ...init });
}

function bearer(token: string): RequestInit {
  return { headers: { authorization: `Bearer ${token}` } };
}

/** Fake GitHub and Google. A provider code is "<subject>|<name>". */
function fakeProviders() {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const url = request.url;
    if (url === "https://github.com/login/oauth/access_token" || url === "https://oauth2.googleapis.com/token") {
      const form = new URLSearchParams(new TextDecoder().decode(await request.arrayBuffer()));
      return Response.json({ access_token: `access:${form.get("code")}` });
    }
    const [subject, name] = (request.headers.get("authorization") ?? "").replace("Bearer access:", "").split("|");
    if (url === "https://api.github.com/user") {
      // GitHub refuses requests without a User-Agent.
      if (!request.headers.get("user-agent")) return new Response("missing user agent", { status: 403 });
      return Response.json({ id: Number(subject), login: name });
    }
    if (url === "https://openidconnect.googleapis.com/v1/userinfo") return Response.json({ sub: subject, name });
    return new Response("unexpected", { status: 599 });
  });
}

async function pkce() {
  const verifier = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
  return { verifier, challenge: toBase64Url(await sha256(encoder.encode(verifier))) };
}

/** Runs start and callback; returns the app's one-time code. */
async function authorize(provider: string, subject: string, name: string, challenge: string): Promise<string> {
  const query = new URLSearchParams({ redirect_uri: APP_REDIRECT, code_challenge: challenge, state: "app-state-1" });
  const start = await call(`/v1/auth/${provider}/start?${query}`);
  expect(start.status).toBe(302);
  const state = new URL(start.headers.get("location")!).searchParams.get("state")!;
  const callback = await call(`/v1/auth/${provider}/callback?${new URLSearchParams({ code: `${subject}|${name}`, state })}`);
  expect(callback.status).toBe(302);
  const back = new URL(callback.headers.get("location")!);
  expect(`${back.protocol}//${back.host}`).toBe(APP_REDIRECT);
  expect(back.searchParams.get("state")).toBe("app-state-1");
  return back.searchParams.get("code")!;
}

function redeem(code: string, codeVerifier: string): Promise<Response> {
  return call("/v1/auth/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code, codeVerifier, deviceName: "Pixel 9" }),
  });
}

async function signIn(provider: string, subject: string, name = "example-user") {
  const { verifier, challenge } = await pkce();
  const response = await redeem(await authorize(provider, subject, name, challenge), verifier);
  expect(response.status).toBe(200);
  return (await response.json()) as { token: string; account: { id: string; provider: string; name: string } };
}

async function registerMac(token: string, accountId: string, key: MacKey, name = "MacBook Pro", room = key.room) {
  const macPublicKey = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
  const sig = await key.sign(encoder.encode(`yardlet-account-mac/1\n${accountId}\n${room}\n${macPublicKey}\n${name}`));
  return call(`/v1/account/macs/${room}`, {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ macKey: macPublicKey, relayKey: key.publicKey, name, sig }),
  });
}

beforeEach(() => {
  fakeProviders();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("sign-in", () => {
  it("lists the configured providers", async () => {
    expect(await (await call("/v1/auth/providers")).json()).toEqual({ providers: ["github", "google"] });
  });

  it("signs in with GitHub through start, callback and the token exchange", async () => {
    const { verifier, challenge } = await pkce();
    const query = new URLSearchParams({ redirect_uri: APP_REDIRECT, code_challenge: challenge, state: "app-state-1" });
    const start = new URL((await call(`/v1/auth/github/start?${query}`)).headers.get("location")!);
    expect(start.origin + start.pathname).toBe("https://github.com/login/oauth/authorize");
    expect(start.searchParams.get("client_id")).toBe("github-client-id");
    expect(start.searchParams.get("redirect_uri")).toBe("https://relay.example.test/v1/auth/github/callback");

    const code = await authorize("github", "1001", "example-user", challenge);
    const response = await redeem(code, verifier);
    const { token, account } = (await response.json()) as { token: string; account: Record<string, string> };
    const id = await accountIdFor("github", "1001");
    expect(account).toEqual({ id, provider: "github", name: "example-user" });
    expect(token).toMatch(new RegExp(`^${id}\\.[A-Za-z0-9_-]{43}$`));
    expect(await (await call("/v1/account", bearer(token))).json()).toEqual({ id, provider: "github", name: "example-user", macs: [] });
  });

  it("signs in with Google, counting a new account apart from a later sign-in", async () => {
    const write = vi.spyOn(env.METRICS!, "writeDataPoint");
    const { account } = await signIn("google", "2002", "Example Person");
    expect(account).toEqual({ id: await accountIdFor("google", "2002"), provider: "google", name: "Example Person" });
    await signIn("google", "2002", "Example Person");
    expect(write.mock.calls.map(([point]) => point?.blobs)).toEqual([
      ["account.signUp", "google"],
      ["account.signIn", "google"],
    ]);
  });

  it("refuses a forged or expired state", async () => {
    const { challenge } = await pkce();
    const query = new URLSearchParams({ redirect_uri: APP_REDIRECT, code_challenge: challenge, state: "app-state-1" });
    const state = new URL((await call(`/v1/auth/github/start?${query}`)).headers.get("location")!).searchParams.get("state")!;
    const forged = `${state.split(".")[0]}.${toBase64Url(new Uint8Array(32))}`;
    const expired = await signState(env.AUTH_STATE_SECRET!, { p: "github", c: challenge, s: "app-state-1", e: Date.now() - 1 });
    for (const bad of [forged, expired]) {
      const response = await call(`/v1/auth/github/callback?${new URLSearchParams({ code: "1003|example-user", state: bad })}`);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "badRequest" });
    }
  });

  it("refuses a wrong code verifier, a reused code and an expired code", async () => {
    const wrong = await pkce();
    const wrongCode = await authorize("github", "1004", "example-user", wrong.challenge);
    expect((await redeem(wrongCode, (await pkce()).verifier)).status).toBe(401);

    const reused = await pkce();
    const reusedCode = await authorize("github", "1004", "example-user", reused.challenge);
    expect((await redeem(reusedCode, reused.verifier)).status).toBe(200);
    expect((await redeem(reusedCode, reused.verifier)).status).toBe(401);

    const late = await pkce();
    const lateCode = await authorize("github", "1004", "example-user", late.challenge);
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(await accountIdFor("github", "1004")));
    await runInDurableObject(stub, (_, state) => {
      state.storage.sql.exec("UPDATE codes SET expires_at = 0");
    });
    expect((await redeem(lateCode, late.verifier)).status).toBe(401);
  });

  it("answers 401 without a valid token", async () => {
    const { token } = await signIn("github", "1005");
    const [id] = token.split(".");
    for (const init of [{}, bearer(`${id}.${toBase64Url(new Uint8Array(32))}`), bearer("not-a-token")]) {
      const response = await call("/v1/account", init);
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
  });
});

describe("account", () => {
  it("enrolls only the specified client key on a registered Mac of the same account, once and before expiry", async () => {
    const owner = await signIn("github", "9011");
    const other = await signIn("github", "9012");
    const host = await macKey();
    const second = await macKey();
    await registerMac(owner.token, owner.account.id, host);
    await registerMac(owner.token, owner.account.id, second);
    const clientKey = (await macKey()).publicKey;
    const post = (path: string, token: string, body: object) =>
      call(path, { ...bearer(token), method: "POST", body: JSON.stringify(body) });
    const path = (room: string) => `/v1/account/macs/${room}/link-grants`;
    const issue = async () => (await (await post(path(host.room), owner.token, { clientKey })).json()) as { grant: string };
    const use = (room: string, token: string, key: string, grant: string) =>
      post(path(room) + "/redeem", token, { clientKey: key, grant });
    expect((await post(path(host.room), other.token, { clientKey })).status).toBe(404);
    const first = await issue();
    expect(first.grant).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect((await use(host.room, other.token, clientKey, first.grant)).status).toBe(403);
    expect((await use(second.room, owner.token, clientKey, first.grant)).status).toBe(403);
    expect((await use(host.room, owner.token, second.publicKey, first.grant)).status).toBe(403);
    const results = await Promise.all([1, 2].map(() => use(host.room, owner.token, clientKey, first.grant)));
    expect(results.map(result => result.status).sort()).toEqual([200, 403]);
    const late = await issue();
    const stub = env.ACCOUNT.get(env.ACCOUNT.idFromName(owner.account.id));
    await runInDurableObject(stub, (_, state) => { state.storage.sql.exec("UPDATE link_grants SET expires_at = 0"); });
    expect((await use(host.room, owner.token, clientKey, late.grant)).status).toBe(403);
    const signedOut = await issue();
    const secondSignIn = await signIn("github", "9011");
    await call("/v1/auth/logout", { ...bearer(owner.token), method: "POST" });
    expect((await use(host.room, secondSignIn.token, clientKey, signedOut.grant)).status).toBe(403);
  });

  it("registers Macs signed with their relay key, at most 20", async () => {
    const { token, account } = await signIn("github", "1006");
    const key = await macKey();
    expect(await (await registerMac(token, account.id, key)).json()).toEqual({ ok: true });
    expect((await registerMac(token, account.id, key, "Renamed Mac")).status).toBe(200);

    const forger = await macKey();
    const wrongSig = await registerMac(token, account.id, {
      ...key,
      sign: forger.sign,
    });
    expect(wrongSig.status).toBe(403);
    expect(await wrongSig.json()).toEqual({ error: "invalidSignature" });
    expect((await registerMac(token, account.id, key, "MacBook Pro", forger.room)).status).toBe(403);

    const listed = (await (await call("/v1/account", bearer(token))).json()) as { macs: Record<string, unknown>[] };
    expect(listed.macs).toEqual([
      { room: key.room, macKey: expect.any(String), relayKey: key.publicKey, name: "Renamed Mac", updatedAt: expect.any(Number) },
    ]);

    for (let i = 1; i < 20; i += 1) expect((await registerMac(token, account.id, await macKey())).status).toBe(200);
    const tooMany = await registerMac(token, account.id, await macKey());
    expect(tooMany.status).toBe(409);
    expect(await tooMany.json()).toEqual({ error: "tooMany" });
  });

  it("removes a Mac, logs out a token and deletes the account", async () => {
    const first = await signIn("github", "1007");
    const second = await signIn("github", "1007");
    const kept = await macKey();
    const removed = await macKey();
    await registerMac(first.token, first.account.id, kept);
    await registerMac(first.token, first.account.id, removed);

    expect((await call(`/v1/account/macs/${removed.room}`, { method: "DELETE", ...bearer(second.token) })).status).toBe(204);
    const listed = (await (await call("/v1/account", bearer(first.token))).json()) as { macs: { room: string }[] };
    expect(listed.macs.map((mac) => mac.room)).toEqual([kept.room]);

    expect((await call("/v1/auth/logout", { method: "POST", ...bearer(second.token) })).status).toBe(204);
    expect((await call("/v1/account", bearer(second.token))).status).toBe(401);
    expect((await call("/v1/account", bearer(first.token))).status).toBe(200);

    expect((await call("/v1/account", { method: "DELETE", ...bearer(first.token) })).status).toBe(204);
    expect((await call("/v1/account", bearer(first.token))).status).toBe(401);
    const again = await signIn("github", "1007");
    expect(await (await call("/v1/account", bearer(again.token))).json()).toMatchObject({ macs: [] });
  });
});
