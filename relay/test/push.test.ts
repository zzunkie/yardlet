import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { fromBase64Url } from "../src/keys";
import { openMac, type Peer } from "./helpers";

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
    const { mac } = await openMac();

    mac.ws.send(push("p1"));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "p1", ok: true }]);
    mac.ws.send(push("p2", { urgent: false, collapse: "fedcba9876543210", ttl: 60 }));
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
    expect(sends.map((r) => r.headers.get("authorization"))).toEqual(["Bearer access-1", "Bearer access-1"]);
    expect(sends.map((r) => JSON.parse(r.body))).toEqual([
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

  it("maps FCM errors", async () => {
    const answers = [
      Response.json({ error: { code: 404, status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }, { status: 404 }),
      Response.json({ error: { code: 400, status: "INVALID_ARGUMENT" } }, { status: 400 }),
      Response.json({ error: { code: 429, status: "RESOURCE_EXHAUSTED" } }, { status: 429 }),
      Response.json({ error: { code: 503, status: "UNAVAILABLE" } }, { status: 503 }),
    ];
    fakeGoogle(() => answers.shift()!);
    const { mac } = await openMac();
    const errors = [];
    for (const id of ["p1", "p2", "p3", "p4"]) {
      mac.ws.send(push(id));
      errors.push((await mac.json()).error);
    }
    expect(errors).toEqual(["unregistered", "invalid", "rateLimited", "unavailable"]);
  });

  it("sends at most 60 a minute per room", async () => {
    const requests = fakeGoogle();
    const { mac } = await openMac();
    for (let i = 0; i < 61; i += 1) mac.ws.send(push(`p${i}`));
    const replies = await pushed(mac, 61);
    expect(replies.filter((r) => r.ok === true)).toHaveLength(60);
    expect(replies.filter((r) => r.ok === false)).toEqual([{ t: "pushed", id: "p60", ok: false, error: "rateLimited" }]);
    expect(requests.filter((r) => r.url === FCM_URL)).toHaveLength(60);
  });

  // First APNs test in this file: the provider token is cached for the isolate.
  it("signs one APNs provider token and sends alerts and background pushes", async () => {
    const requests = fakeApple();
    const { mac } = await openMac();
    const before = Math.floor(Date.now() / 1000);

    mac.ws.send(push("a1", { provider: "apns", to: DEVICE }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a1", ok: true }]);
    mac.ws.send(push("a2", { provider: "apns-sandbox", to: DEVICE, urgent: false, collapse: "fedcba9876543210", ttl: 60 }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a2", ok: true }]);
    const after = Math.floor(Date.now() / 1000);

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
    mac.ws.send(push("a3", { provider: "apns", to: DEVICE }));
    expect(await pushed(mac)).toEqual([{ t: "pushed", id: "a3", ok: true }]);
    expect(requests[2].headers.get("authorization")).not.toBe(authorization);
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
    const requests = fakeApple(() => {
      const [status, reason] = answers.shift()!;
      return reason ? Response.json({ reason }, { status }) : new Response(null, { status });
    });
    const { mac } = await openMac();
    const errors = [];
    for (let i = 0; i < 9; i += 1) {
      mac.ws.send(push(`a${i}`, { provider: "apns", to: DEVICE }));
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
    const tokens = requests.map((r) => r.headers.get("authorization"));
    expect(new Set(tokens.slice(0, 8)).size).toBe(1);
    expect(tokens[8]).not.toBe(tokens[0]);

    // Refused before reaching Apple: a provider the relay does not know, a token that names no device.
    mac.ws.send(push("x1", { provider: "webpush", to: DEVICE }));
    mac.ws.send(push("x2", { provider: "apns", to: "not/a/token" }));
    expect(await pushed(mac, 2)).toEqual([
      { t: "pushed", id: "x1", ok: false, error: "invalid" },
      { t: "pushed", id: "x2", ok: false, error: "unregistered" },
    ]);
    expect(requests).toHaveLength(9);
  });
});
