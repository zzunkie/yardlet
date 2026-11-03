import { exports } from "cloudflare:workers";
import { afterEach, expect, it, vi } from "vitest";
import { RELAY, openMac } from "./helpers";

afterEach(() => {
  vi.restoreAllMocks();
});

it("answers notConfigured without FCM or APNs credentials", async () => {
  const fetch = vi.spyOn(globalThis, "fetch");
  const { mac } = await openMac();
  mac.ws.send(JSON.stringify({ t: "push", id: "p1", to: "registration-token-1", urgent: true, data: { v: "1" } }));
  expect(await mac.json()).toEqual({ t: "pushed", id: "p1", ok: false, error: "notConfigured" });
  mac.ws.send(JSON.stringify({ t: "push", id: "p2", provider: "apns", to: "00fe", urgent: true, data: { v: "1" } }));
  expect(await mac.json()).toEqual({ t: "pushed", id: "p2", ok: false, error: "notConfigured" });
  expect(fetch).not.toHaveBeenCalled();
});

it("offers no sign-in provider without their credentials", async () => {
  const providers = await exports.default.fetch(`${RELAY}/v1/auth/providers`);
  expect(await providers.json()).toEqual({ providers: [] });
  const start = await exports.default.fetch(`${RELAY}/v1/auth/github/start?redirect_uri=yardlet-remote://auth`);
  expect(start.status).toBe(501);
  expect(await start.json()).toEqual({ error: "notConfigured" });
});
