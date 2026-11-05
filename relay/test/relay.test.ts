import { env, exports } from "cloudflare:workers";
import { evictDurableObject, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { hostChallengeMessage } from "../src/keys";
import { roomLocation, roomObjectName } from "../src/placement";
import { RELAY, connect, macFrame, macKey, openMac, openPhone, upgrade } from "./helpers";

const bytes = (...values: number[]) => new Uint8Array(values);

describe("routes", () => {
  it("answers health", async () => {
    const response = await exports.default.fetch(`${RELAY}/v1/health`);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("ok");
  });

  it("places a room by the country it is first asked for from", () => {
    expect(roomLocation("KR", "AS")).toBe("apac-ne");
    expect(roomLocation("SG", "AS")).toBe("apac-se");
    expect(roomLocation("IN", "AS")).toBe("apac");
    expect(roomLocation("TR", "EU")).toBe("me");
    expect(roomLocation("BR", "SA")).toBe("sam");
    expect(roomLocation("ZA", "AF")).toBe("afr");
    expect(roomLocation("AU", "OC")).toBe("oc");
    // Networks that already arrive nearby keep Cloudflare's own choice.
    expect(roomLocation("US", "NA")).toBeUndefined();
    expect(roomLocation("DE", "EU")).toBeUndefined();
    expect(roomLocation(undefined, undefined)).toBeUndefined();
  });

  it("refuses malformed rooms", async () => {
    for (const room of ["a".repeat(31), "a".repeat(33), "A".repeat(32), "1".repeat(32), "0".repeat(32)]) {
      expect((await upgrade(`/v1/rooms/${room}/host`)).status).toBe(400);
      expect((await upgrade(`/v1/rooms/${room}/connect`)).status).toBe(400);
    }
  });
});

describe("the Mac's socket", () => {
  it("opens the room after a valid signature", async () => {
    const key = await macKey();
    const mac = await connect(`/v1/rooms/${key.room}/host`);
    const challenge = await mac.json();
    expect(challenge.t).toBe("challenge");
    expect(challenge.nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const sig = await key.sign(hostChallengeMessage(key.room, challenge.nonce as string));
    mac.ws.send(JSON.stringify({ t: "auth", key: key.publicKey, sig }));
    expect(await mac.json()).toEqual({ t: "ready" });
  });

  it("closes with 4401 when the key does not own the room", async () => {
    const owner = await macKey();
    const other = await macKey();
    const mac = await connect(`/v1/rooms/${owner.room}/host`);
    const { nonce } = await mac.json();
    const sig = await other.sign(hostChallengeMessage(owner.room, nonce as string));
    mac.ws.send(JSON.stringify({ t: "auth", key: other.publicKey, sig }));
    expect(await mac.closeCode()).toBe(4401);
  });

  it("closes with 4401 on a wrong signature", async () => {
    const key = await macKey();
    const mac = await connect(`/v1/rooms/${key.room}/host`);
    await mac.json();
    const sig = await key.sign(hostChallengeMessage(key.room, "another-nonce"));
    mac.ws.send(JSON.stringify({ t: "auth", key: key.publicKey, sig }));
    expect(await mac.closeCode()).toBe(4401);
  });

  it("closes with 4408 when no auth comes in time", async () => {
    const key = await macKey();
    const mac = await connect(`/v1/rooms/${key.room}/host`);
    await mac.json();
    const stub = env.ROOM.get(env.ROOM.idFromName(roomObjectName(key.room)));
    // Move the 10 s deadline into the past rather than waiting for it.
    await runInDurableObject(stub, (_, state) => {
      for (const ws of state.getWebSockets("mac")) {
        ws.serializeAttachment({ ...(ws.deserializeAttachment() as object), deadline: 0 });
      }
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await mac.closeCode()).toBe(4408);
  });

  it("answers ping with pong", async () => {
    const { mac } = await openMac();
    mac.ws.send("ping");
    expect(await mac.next()).toBe("pong");
  });

  it("replaces an older Mac socket and closes it and its phones with 4409", async () => {
    const { mac: older, key } = await openMac();
    const { phone, c } = await openPhone(key.room, older);
    const { mac: newer } = await openMac(key);
    expect(await older.closeCode()).toBe(4409);
    expect(await phone.closeCode()).toBe(4409);

    const next = await openPhone(key.room, newer);
    expect(next.c).toBeGreaterThan(c);
    next.phone.ws.send(bytes(1));
    expect(await newer.binary()).toEqual(macFrame(next.c, bytes(1)));
  });
});

describe("a phone's socket", () => {
  it("gets 404 when no Mac holds the room", async () => {
    const key = await macKey();
    expect((await upgrade(`/v1/rooms/${key.room}/connect`)).status).toBe(404);
    // A Mac that has not authenticated does not hold it either.
    const mac = await connect(`/v1/rooms/${key.room}/host`);
    await mac.json();
    expect((await upgrade(`/v1/rooms/${key.room}/connect`)).status).toBe(404);
  });

  it("forwards frames both ways with connection numbers", async () => {
    const { mac, key } = await openMac();
    const first = await openPhone(key.room, mac);
    const second = await openPhone(key.room, mac);
    expect(first.c).toBe(1);
    expect(second.c).toBe(2);

    second.phone.ws.send(bytes(9, 8, 7));
    expect(await mac.binary()).toEqual(macFrame(2, bytes(9, 8, 7)));
    first.phone.ws.send(bytes(1));
    expect(await mac.binary()).toEqual(macFrame(1, bytes(1)));

    mac.ws.send(macFrame(1, bytes(4, 5)));
    mac.ws.send(macFrame(2, bytes(6)));
    expect(await first.phone.binary()).toEqual(bytes(4, 5));
    expect(await second.phone.binary()).toEqual(bytes(6));
  });

  it("tells the Mac when a phone leaves", async () => {
    const { mac, key } = await openMac();
    const { phone, c } = await openPhone(key.room, mac);
    phone.ws.close(1000, "bye");
    expect(await mac.json()).toEqual({ t: "closed", c, code: 1000 });
  });

  it("closes a phone with the code the Mac asks for", async () => {
    const { mac, key } = await openMac();
    const { phone, c } = await openPhone(key.room, mac);
    mac.ws.send(JSON.stringify({ t: "close", c, code: 4403 }));
    expect(await phone.closeCode()).toBe(4403);
  });

  it("closes every phone with 4404 when the Mac leaves", async () => {
    const { mac, key } = await openMac();
    const { phone } = await openPhone(key.room, mac);
    mac.ws.close(1000);
    expect(await phone.closeCode()).toBe(4404);
    expect((await upgrade(`/v1/rooms/${key.room}/connect`)).status).toBe(404);
  });

  it("refuses a ninth phone the Mac answered with 429", async () => {
    const { mac, key } = await openMac();
    for (let i = 0; i < 8; i += 1) {
      const { phone, c } = await openPhone(key.room, mac);
      mac.ws.send(macFrame(c, bytes(0)));
      await phone.binary();
    }
    expect((await upgrade(`/v1/rooms/${key.room}/connect`)).status).toBe(429);
  });

  it("lets a phone in past sockets the Mac never answered", async () => {
    const { mac, key } = await openMac();
    const first = await openPhone(key.room, mac);
    await openPhone(key.room, mac);
    // A third from the same address closes the oldest that is still unanswered.
    const thirdPhone = await connect(`/v1/rooms/${key.room}/connect`);
    expect(await mac.json()).toEqual({ t: "closed", c: first.c, code: 4503 });
    const third = { phone: thirdPhone, c: (await mac.json()).c as number };
    expect(await first.phone.closeCode()).toBe(4503);
    mac.ws.send(macFrame(third.c, bytes(1)));
    expect(await third.phone.binary()).toEqual(bytes(1));

    // One the Mac does not answer in time is closed.
    const silent = await openPhone(key.room, mac);
    const stub = env.ROOM.get(env.ROOM.idFromName(roomObjectName(key.room)));
    await runInDurableObject(stub, (_, state) => {
      for (const ws of state.getWebSockets(`c${silent.c}`)) {
        ws.serializeAttachment({ ...(ws.deserializeAttachment() as object), openedAt: 0 });
      }
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await silent.phone.closeCode()).toBe(4408);
    // The answered one stays.
    mac.ws.send(macFrame(third.c, bytes(2)));
    expect(await third.phone.binary()).toEqual(bytes(2));
  });

  it("closes a phone that sends text (1003) or an oversized frame (1009)", async () => {
    const { mac, key } = await openMac();
    const text = await openPhone(key.room, mac);
    text.phone.ws.send("hello");
    expect(await text.phone.closeCode()).toBe(1003);
    expect(await mac.json()).toEqual({ t: "closed", c: text.c, code: 1003 });

    const large = await openPhone(key.room, mac);
    large.phone.ws.send(new Uint8Array(65_536));
    expect(await large.phone.closeCode()).toBe(1009);
    expect(await mac.json()).toEqual({ t: "closed", c: large.c, code: 1009 });
  });

  it("keeps forwarding after the room is evicted from memory", async () => {
    const { mac, key } = await openMac();
    const { phone, c } = await openPhone(key.room, mac);
    await evictDurableObject(env.ROOM.get(env.ROOM.idFromName(roomObjectName(key.room))));

    phone.ws.send(bytes(3));
    expect(await mac.binary()).toEqual(macFrame(c, bytes(3)));
    mac.ws.send(macFrame(c, bytes(2)));
    expect(await phone.binary()).toEqual(bytes(2));
    expect((await openPhone(key.room, mac)).c).toBe(c + 1);
  });
});
