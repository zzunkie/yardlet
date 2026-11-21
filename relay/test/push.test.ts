import { env, exports } from "cloudflare:workers";
import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fromBase64Url } from "../src/keys";
import { roomObjectName } from "../src/placement";
import { rawFcmTokensUntil } from "../src/room";
import { RELAY, macKey, openMac, registerTarget, removeTarget, type Peer } from "./helpers";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FCM_URL = "https://fcm.googleapis.com/v1/projects/relay-test/messages:send";
const DEVICE = "00fe".repeat(16);

interface Captured {
  url: string;
  headers: Headers;
  body: string;
}

function push(id: string, fields: Record<string, unknown> = {}) {
  return JSON.stringify({
    t: "push",
    id,
    to: "registration-token-1",
    urgent: true,
    collapse: "0123456789abcdef",
    ttl: 3600,
    data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
    ...fields,
  });
}

/** Answers the OAuth token endpoint and FCM; `fcm` decides FCM's response. */
function fakeGoogle(fcm: (body: Record<string, any>) => Response = () => Response.json({ name: "projects/relay-test/messages/1" })) {
  const requests: Captured[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const body = new TextDecoder().decode(await request.arrayBuffer());
    const captured = { url: request.url, headers: request.headers, body };
    requests.push(captured);
    if (captured.url === TOKEN_URL) return Response.json({ access_token: "access-1", expires_in: 3599, token_type: "Bearer" });
    if (captured.url === FCM_URL) return fcm(JSON.parse(captured.body));
    return new Response("unexpected", { status: 599 });
  });
  return requests;
}

/** Answers APNs; `apns` decides its response. */
function fakeApple(apns: (request: Captured) => Response = () => new Response(null, { headers: { "apns-id": crypto.randomUUID() } })) {
  const requests: Captured[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const captured = { url: request.url, headers: request.headers, body: await request.text() };
    requests.push(captured);
    return apns(captured);
  });
  return requests;
}

const decode = (part: string) => JSON.parse(new TextDecoder().decode(fromBase64Url(part)!));

/** What a push from the relay offered (§14.5), when `request` is one. */
function offerOf(request: Captured): { pushTarget: string; room: string } | undefined {
  let body: any;
  try {
    body = JSON.parse(request.body);
  } catch {
    return undefined;
  }
  const data = request.url === FCM_URL ? body?.message?.data : body;
  return typeof data?.pushTarget === "string" ? { pushTarget: data.pushTarget, room: data.room } : undefined;
}

const isOffer = (request: Captured) => offerOf(request) !== undefined;

/** Registers `token` in `room` as its phone does: the target it holds comes back, or one arrives in a push. */
async function target(requests: Captured[], room: string, provider: string, token: string, held?: string): Promise<string> {
  const before = requests.length;
  const response = await registerTarget(room, provider, token, held);
  if (response.status === 200) return ((await response.json()) as { target: string }).target;
  expect(response.status).toBe(202);
  expect(await response.json()).toEqual({ sent: true });
  const offer = requests.slice(before).map(offerOf).find((found) => found !== undefined);
  expect(offer?.room).toBe(room);
  return offer!.pushTarget;
}

async function pushed(mac: Peer, count = 1): Promise<Record<string, unknown>[]> {
  const replies = [];
  for (let i = 0; i < count; i += 1) replies.push(await mac.json());
  return replies;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("push", () => {
  // First in this file: the access token is cached for the isolate.
  it("signs one OAuth assertion and sends FCM data messages", async () => {
    const requests = fakeGoogle();
    const { mac, key } = await openMac();
    const to = await target(requests, key.room, "fcm", "registration-token-1");

    mac.ws.send(push("p1", { to }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "p1", ok: true }]);
    mac.ws.send(push("p2", { to, urgent: false, collapse: "fedcba9876543210", ttl: 60 }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "p2", ok: true }]);

    const tokenRequests = requests.filter((r) => r.url === TOKEN_URL);
    expect(tokenRequests).toHaveLength(1);
    const form = new URLSearchParams(tokenRequests[0].body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const [header, claims, signature] = form.get("assertion")!.split(".");
    expect(decode(header)).toEqual({ alg: "RS256", typ: "JWT" });
    const payload = decode(claims);
    expect(payload).toMatchObject({
      iss: "relay-test@example.test",
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: TOKEN_URL,
    });
    expect(payload.exp - payload.iat).toBe(3600);
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      JSON.parse((env as unknown as { TEST_FCM_PUBLIC_JWK: string }).TEST_FCM_PUBLIC_JWK),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${header}.${claims}`);
    expect(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", publicKey, fromBase64Url(signature)!, signed)).toBe(true);

    const sends = requests.filter((r) => r.url === FCM_URL);
    expect(sends.map((r) => r.headers.get("authorization"))).toEqual(["Bearer access-1", "Bearer access-1", "Bearer access-1"]);
    expect(sends.map((r) => JSON.parse(r.body))).toEqual([
      {
        message: {
          token: "registration-token-1",
          data: { pushTarget: to, room: key.room },
          android: { priority: "HIGH", ttl: "300s" },
        },
      },
      {
        message: {
          token: "registration-token-1",
          data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
          android: { priority: "HIGH", collapse_key: "0123456789abcdef", ttl: "3600s" },
        },
      },
      {
        message: {
          token: "registration-token-1",
          data: { v: "1", k: "0011223344556677", y: "c2VhbGVk" },
          android: { priority: "NORMAL", collapse_key: "fedcba9876543210", ttl: "60s" },
        },
      },
    ]);
  });

  it("maps FCM errors and forgets a target whose token FCM no longer knows", async () => {
    const answers = [
      Response.json({ error: { code: 400, status: "INVALID_ARGUMENT" } }, { status: 400 }),
      Response.json({ error: { code: 429, status: "RESOURCE_EXHAUSTED" } }, { status: 429 }),
      Response.json({ error: { code: 503, status: "UNAVAILABLE" } }, { status: 503 }),
      Response.json({ error: { code: 404, status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }, { status: 404 }),
    ];
    const requests = fakeGoogle((body) => (body.message.data.pushTarget ? Response.json({ name: "offered" }) : answers.shift()!));
    const { mac, key } = await openMac();
    const to = await target(requests, key.room, "fcm", "registration-token-1");
    const errors = [];
    for (const id of ["p1", "p2", "p3", "p4", "p5"]) {
      mac.ws.send(push(id, { to }));
      errors.push((await mac.json()).error);
    }
    expect(errors).toEqual(["invalid", "rateLimited", "unavailable", "unregistered", "unregistered"]);
    expect(requests.filter((r) => r.url === FCM_URL && !isOffer(r))).toHaveLength(4);
  });

  it("sends at most 60 a minute per room, a target's own push among them", async () => {
    const requests = fakeGoogle();
    const { mac, key } = await openMac();
    const to = await target(requests, key.room, "fcm", "registration-token-1");
    for (let i = 0; i < 60; i += 1) mac.ws.send(push(`p${i}`, { to }));
    const replies = await pushed(mac, 60);
    expect(replies.filter((r) => r.ok === true)).toHaveLength(59);
    expect(replies.filter((r) => r.ok === false)).toEqual([{ t: "pushed", id: "p59", ok: false, error: "rateLimited" }]);
    expect(requests.filter((r) => r.url === FCM_URL)).toHaveLength(60);
  });

  // First APNs test in this file: the provider token is cached for the isolate.
  it("signs one APNs provider token and sends alerts and background pushes", async () => {
    const captured = fakeApple();
    const { mac, key } = await openMac();
    const production = await target(captured, key.room, "apns", DEVICE);
    const sandbox = await target(captured, key.room, "apns-sandbox", DEVICE);
    const requests = captured.filter((r) => !isOffer(r));
    const before = Math.floor(Date.now() / 1000);

    mac.ws.send(push("a1", { provider: "apns", to: production }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a1", ok: true }]);
    mac.ws.send(push("a2", { provider: "apns-sandbox", to: sandbox, urgent: false, collapse: "fedcba9876543210", ttl: 60 }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a2", ok: true }]);
    const after = Math.floor(Date.now() / 1000);
    requests.push(...captured.slice(2));

    expect(requests.map((r) => r.url)).toEqual([
      `https://api.push.apple.com/3/device/${DEVICE}`,
      `https://api.sandbox.push.apple.com/3/device/${DEVICE}`,
    ]);
    const apnsHeaders = (r: Captured) => Object.fromEntries([...r.headers].filter(([name]) => name.startsWith("apns-")));
    const [alert, background] = requests;
    expect(apnsHeaders(alert)).toEqual({
      "apns-topic": "app.example.remote",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": "0123456789abcdef",
      "apns-expiration": expect.any(String),
    });
    expect(Number(alert.headers.get("apns-expiration"))).toBeGreaterThanOrEqual(before + 3600);
    expect(Number(alert.headers.get("apns-expiration"))).toBeLessThanOrEqual(after + 3600);
    expect(apnsHeaders(background)).toMatchObject({
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-collapse-id": "fedcba9876543210",
    });
    expect(JSON.parse(alert.body)).toEqual({
      aps: {
        alert: { "title-loc-key": "PUSH_FALLBACK_TITLE", "loc-key": "PUSH_FALLBACK_BODY" },
        "mutable-content": 1,
        sound: "default",
      },
      v: "1",
      k: "0011223344556677",
      y: "c2VhbGVk",
    });
    expect(JSON.parse(background.body)).toEqual({ aps: { "content-available": 1 }, v: "1", k: "0011223344556677", y: "c2VhbGVk" });

    const authorization = alert.headers.get("authorization")!;
    expect(background.headers.get("authorization")).toBe(authorization);
    const [scheme, jwt] = authorization.split(" ");
    expect(scheme).toBe("bearer");
    const [header, claims, signature] = jwt.split(".");
    expect(decode(header)).toEqual({ alg: "ES256", kid: "KEY1234567" });
    const payload = decode(claims);
    expect(payload).toEqual({ iss: "TEAM123456", iat: expect.any(Number) });
    expect(payload.iat).toBeGreaterThanOrEqual(before);
    expect(payload.iat).toBeLessThanOrEqual(after);
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      JSON.parse((env as unknown as { TEST_APNS_PUBLIC_JWK: string }).TEST_APNS_PUBLIC_JWK),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const signed = new TextEncoder().encode(`${header}.${claims}`);
    expect(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromBase64Url(signature)!, signed)).toBe(true);

    // Apple takes a new token at most every 20 minutes and refuses one older than 60: one serves 50.
    const now = Date.now;
    vi.spyOn(Date, "now").mockImplementation(() => now.call(Date) + 50 * 60_000);
    mac.ws.send(push("a3", { provider: "apns", to: production }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a3", ok: true }]);
    expect(captured[4].headers.get("authorization")).not.toBe(authorization);
  });

  it("maps APNs errors and signs a fresh token after Apple refuses one", async () => {
    // Made when the room asks, so the room can read their bodies.
    const answers: [number, string?][] = [
      [410, "Unregistered"],
      [400, "BadDeviceToken"],
      [400, "DeviceTokenNotForTopic"],
      [400, "BadCollapseId"],
      [413, "PayloadTooLarge"],
      [429, "TooManyRequests"],
      [503, "ServiceUnavailable"],
      [403, "ExpiredProviderToken"],
      [200],
    ];
    const captured = fakeApple((request) => {
      if (isOffer(request)) return new Response(null, { status: 200 });
      const [status, reason] = answers.shift()!;
      return reason ? Response.json({ reason }, { status }) : new Response(null, { status });
    });
    const requests = () => captured.filter((r) => !isOffer(r));
    const { mac, key } = await openMac();
    const errors = [];
    let to: string | undefined;
    for (let i = 0; i < 9; i += 1) {
      // A target whose token Apple no longer knows goes, and the next registration is sent a new one.
      to = await target(captured, key.room, "apns", DEVICE, to);
      mac.ws.send(push(`a${i}`, { provider: "apns", to }));
      errors.push((await mac.json()).error);
    }
    expect(errors).toEqual([
      "unregistered",
      "unregistered",
      "unregistered",
      "invalid",
      "invalid",
      "rateLimited",
      "unavailable",
      "unavailable",
      undefined,
    ]);
    const tokens = requests().map((r) => r.headers.get("authorization"));
    expect(new Set(tokens.slice(0, 8)).size).toBe(1);
    expect(tokens[8]).not.toBe(tokens[0]);

    // Refused before reaching Apple: a provider the relay does not know, a token rather than a target.
    mac.ws.send(push("x1", { provider: "webpush", to: DEVICE }));
    mac.ws.send(push("x2", { provider: "apns", to: DEVICE }));
    expect(await pushed(mac, 2)).toEqual([
      { t: "pushed", id: "x1", ok: false, error: "invalid" },
      { t: "pushed", id: "x2", ok: false, error: "unregistered" },
    ]);
    expect(requests()).toHaveLength(9);
  });

  it("sends a target only to the token's own phone, and pushes only to one the sending room holds", async () => {
    const captured = fakeApple();
    const requests = () => captured.filter((r) => !isOffer(r));
    const { mac, key } = await openMac();
    const { mac: other, key: otherKey } = await openMac();
    const unregistered = (id: string) => ({ t: "pushed", id, ok: false, error: "unregistered" });

    // The target goes to the phone as a background push; the registration's answer holds none.
    const to = await target(captured, key.room, "apns", DEVICE);
    const [offer] = captured;
    expect(offer.url).toBe(`https://api.push.apple.com/3/device/${DEVICE}`);
    expect(offer.headers.get("apns-push-type")).toBe("background");
    expect(offer.headers.get("apns-priority")).toBe("5");
    expect(JSON.parse(offer.body)).toEqual({ pushTarget: to, room: key.room, aps: { "content-available": 1 } });

    // Another Mac that knows the token registers it in its own room: the phone is sent a target the Mac never sees,
    // and the first room's target does not work from there.
    const taken = await registerTarget(otherKey.room, "apns", DEVICE);
    expect(taken.status).toBe(202);
    expect(await taken.json()).toEqual({ sent: true });
    expect(offerOf(captured[1])?.room).toBe(otherKey.room);
    other.ws.send(push("o1", { provider: "apns", to }));
    expect(await pushed(other)).toEqual([unregistered("o1")]);
    mac.ws.send(push("o2", { provider: "apns", to: "A".repeat(43) }));
    expect(await pushed(mac)).toEqual([unregistered("o2")]);
    expect(requests()).toHaveLength(0);

    mac.ws.send(push("a1", { provider: "apns", to }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a1", ok: true }]);
    expect(requests().map((r) => r.url)).toEqual([`https://api.push.apple.com/3/device/${DEVICE}`]);

    // The phone naming its target gets it back; anyone else is sent nothing again for 30 seconds.
    expect((await registerTarget(key.room, "apns", DEVICE)).status).toBe(429);
    const room = env.ROOM.get(env.ROOM.idFromName(roomObjectName(key.room)));
    await evictDurableObject(room);
    const { mac: again } = await openMac(key);
    expect(await target(captured, key.room, "apns", DEVICE, to)).toBe(to);
    again.ws.send(push("a2", { provider: "apns", to }));
    expect(await pushed(again)).toEqual([{ t: "pushed", id: "a2", ok: true }]);

    // A target the phone removed ends, whether or not the Mac is there.
    again.ws.close();
    expect((await removeTarget(key.room, to)).status).toBe(204);
    const { mac: third } = await openMac(key);
    third.ws.send(push("a3", { provider: "apns", to }));
    expect(await pushed(third)).toEqual([unregistered("a3")]);
    expect(requests()).toHaveLength(2);

    // One nobody registered or pushed to for 90 days ends, and the room then stores nothing.
    const idle = await target(captured, key.room, "apns", DEVICE, to);
    expect(idle).not.toBe(to);
    vi.spyOn(Date, "now").mockReturnValue(Date.now() + 90 * 24 * 60 * 60_000);
    expect(await runDurableObjectAlarm(room)).toBe(true);
    third.ws.send(push("a4", { provider: "apns", to: idle }));
    expect(await pushed(third)).toEqual([unregistered("a4")]);
    const tables = await runInDurableObject(room, (_, state) => state.storage.sql.exec("SELECT name FROM sqlite_master").toArray());
    expect(tables.filter((table) => table.name === "push_targets")).toEqual([]);
  });

  it("keeps no target for a token the service refuses", async () => {
    fakeApple(() => Response.json({ reason: "BadDeviceToken" }, { status: 400 }));
    const { key } = await openMac();
    const refused = await registerTarget(key.room, "apns", DEVICE);
    expect(refused.status).toBe(410);
    expect(await refused.json()).toEqual({ error: "unregistered" });
    const room = env.ROOM.get(env.ROOM.idFromName(roomObjectName(key.room)));
    const tables = await runInDurableObject(room, (_, state) => state.storage.sql.exec("SELECT name FROM sqlite_master").toArray());
    expect(tables.filter((table) => table.name === "push_targets")).toEqual([]);
  });

  it("sends to an FCM token named by the Mac itself only until the transition ends", async () => {
    const requests = fakeGoogle();
    const { mac } = await openMac();
    const clock = vi.spyOn(Date, "now").mockReturnValue(rawFcmTokensUntil - 1);
    mac.ws.send(push("f1"));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "f1", ok: true }]);
    clock.mockReturnValue(rawFcmTokensUntil);
    mac.ws.send(push("f2"));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "f2", ok: false, error: "unregistered" }]);
    expect(requests.filter((r) => r.url === FCM_URL).map((r) => JSON.parse(r.body).message.token)).toEqual([
      "registration-token-1",
    ]);
  });

  it("takes a well-formed registration while the room's Mac is there, up to 64 targets", async () => {
    const captured = fakeApple((request) =>
      request.url === TOKEN_URL ? Response.json({ access_token: "access-1", expires_in: 3599 }) : new Response(null),
    );
    const key = await macKey();
    expect((await registerTarget(key.room, "apns", DEVICE)).status).toBe(404);
    await openMac(key);
    const malformed: [string, string][] = [
      ["webpush", DEVICE],
      ["apns", "not hex"],
      ["fcm", "has space"],
      ["fcm", ""],
      ["fcm", "x".repeat(4097)],
    ];
    const held = await registerTarget(key.room, "fcm", "t", "short");
    expect(held.status).toBe(400);
    for (const [provider, token] of malformed) {
      const response = await registerTarget(key.room, provider, token);
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "badRequest" });
    }
    expect((await removeTarget(key.room, "short")).status).toBe(400);
    expect((await exports.default.fetch(`${RELAY}/v1/rooms/${key.room}/push-targets`)).status).toBe(405);
    const large = await exports.default.fetch(`${RELAY}/v1/rooms/${key.room}/push-targets`, {
      method: "POST",
      body: JSON.stringify({ provider: "fcm", token: "t", padding: "x".repeat(8192) }),
    });
    expect(large.status).toBe(413);

    // APNs' hex is one token in either case.
    const apns = await target(captured, key.room, "apns", DEVICE.toUpperCase());
    expect(await target(captured, key.room, "apns", DEVICE, apns)).toBe(apns);
    // Two seconds pass at each reading of the clock, so the room's minute of pushes never runs out.
    let now = Date.now();
    vi.spyOn(Date, "now").mockImplementation(() => (now += 2_000));
    for (let i = 1; i < 64; i += 1) expect((await registerTarget(key.room, "fcm", `token-${i}`)).status).toBe(202);
    const full = await registerTarget(key.room, "fcm", "token-64");
    expect(full.status).toBe(409);
    expect(await full.json()).toEqual({ error: "tooMany" });
    expect(await target(captured, key.room, "apns", DEVICE, apns)).toBe(apns);
  });
});
