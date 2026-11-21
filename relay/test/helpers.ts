import { exports } from "cloudflare:workers";
import { hostChallengeMessage, roomForKey, toBase64Url } from "../src/keys";

export const RELAY = "https://relay.example.test";

type Frame = string | ArrayBuffer;

/** A test-side WebSocket that queues what it receives. */
export class Peer {
  private readonly frames: Frame[] = [];
  private readonly waiting: ((frame: Frame) => void)[] = [];
  readonly closed: Promise<{ code: number; reason: string }>;

  constructor(readonly ws: WebSocket) {
    ws.binaryType = "arraybuffer";
    ws.accept();
    ws.addEventListener("message", (event) => {
      const frame = event.data as Frame;
      const waiter = this.waiting.shift();
      if (waiter) waiter(frame);
      else this.frames.push(frame);
    });
    this.closed = new Promise((resolve) => {
      ws.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
    });
  }

  next(): Promise<Frame> {
    const frame = this.frames.shift();
    if (frame !== undefined) return Promise.resolve(frame);
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  async json(): Promise<Record<string, unknown>> {
    const frame = await this.next();
    if (typeof frame !== "string") throw new Error("expected a text frame");
    return JSON.parse(frame) as Record<string, unknown>;
  }

  async binary(): Promise<Uint8Array> {
    const frame = await this.next();
    if (typeof frame === "string") throw new Error(`expected a binary frame, got ${frame}`);
    return new Uint8Array(frame);
  }

  async closeCode(): Promise<number> {
    return (await this.closed).code;
  }
}

export function upgrade(path: string): Promise<Response> {
  return exports.default.fetch(`${RELAY}${path}`, { headers: { Upgrade: "websocket" } });
}

export async function connect(path: string): Promise<Peer> {
  const response = await upgrade(path);
  if (!response.webSocket) throw new Error(`no upgrade: ${response.status}`);
  return new Peer(response.webSocket);
}

export interface MacKey {
  room: string;
  publicKey: string;
  sign(message: Uint8Array): Promise<string>;
}

export async function macKey(): Promise<MacKey> {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return {
    room: await roomForKey(raw),
    publicKey: toBase64Url(raw),
    sign: async (message) =>
      toBase64Url(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, message))),
  };
}

/** Opens `key`'s room as its Mac and waits for `ready`. */
export async function openMac(key?: MacKey): Promise<{ mac: Peer; key: MacKey }> {
  const k = key ?? (await macKey());
  const mac = await connect(`/v1/rooms/${k.room}/host`);
  const challenge = await mac.json();
  const sig = await k.sign(hostChallengeMessage(k.room, challenge.nonce as string));
  mac.ws.send(JSON.stringify({ t: "auth", key: k.publicKey, sig }));
  const ready = await mac.json();
  if (ready.t !== "ready") throw new Error(`not ready: ${JSON.stringify(ready)}`);
  return { mac, key: k };
}

/** Connects a phone and returns it with the connection number the Mac was told. */
export async function openPhone(room: string, mac: Peer): Promise<{ phone: Peer; c: number }> {
  const phone = await connect(`/v1/rooms/${room}/connect`);
  const open = await mac.json();
  if (open.t !== "open") throw new Error(`expected open: ${JSON.stringify(open)}`);
  return { phone, c: open.c as number };
}

/** Asks to bind a push token to `room` as a phone does (§14.5), naming the target it holds, if any. */
export function registerTarget(room: string, provider: string, token: string, held?: string): Promise<Response> {
  return exports.default.fetch(`${RELAY}/v1/rooms/${room}/push-targets`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ provider, token, target: held }),
  });
}

export function removeTarget(room: string, target: string): Promise<Response> {
  return exports.default.fetch(`${RELAY}/v1/rooms/${room}/push-targets`, {
    method: "DELETE",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ target }),
  });
}

export function macFrame(c: number, payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(4 + payload.length);
  new DataView(frame.buffer).setUint32(0, c);
  frame.set(payload, 4);
  return frame;
}
