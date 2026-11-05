import { DurableObject } from "cloudflare:workers";
import { apnsCredentials, sendApnsPush } from "./apns";
import { fcmCredentials, parsePush, sendFcmPush, type Push, type PushError } from "./fcm";
import { toBase64Url, verifyHostAuth } from "./keys";
import { moveRoomPath } from "./placement";

/** Phones the Mac answered. */
const MAX_PHONES = 8;
/** Phones the Mac has not answered yet, in all and from one address; a new one past these closes the oldest. */
const MAX_WAITING_PHONES = 8;
const MAX_WAITING_PER_ADDRESS = 2;
/** How long a phone may wait for the Mac's first frame. */
const PHONE_ANSWER_MS = 15_000;
const MAX_PHONE_FRAME = 65_535;
const AUTH_TIMEOUT_MS = 10_000;
const PHONE_IDLE_MS = 120_000;
const PUSH_WINDOW_MS = 60_000;
const PUSH_LIMIT = 60;

// Socket state lives in attachments so it survives hibernation.
interface MacState {
  role: "mac";
  room: string;
  nonce: string;
  deadline: number;
  ready: boolean;
  closed: boolean;
  /** The next phone connection number. */
  next: number;
  pushWindowStart: number;
  pushCount: number;
}

interface PhoneState {
  role: "phone";
  c: number;
  lastFrame: number;
  closed: boolean;
  /** The Mac sent this phone a frame. Absent on sockets from before it was kept, which count as answered. */
  answered?: boolean;
  openedAt?: number;
  address?: string;
}

type SocketState = MacState | PhoneState;

interface Held<S> {
  ws: WebSocket;
  state: S;
}

/** One Mac's room: forwards frames between its socket and up to 8 phone sockets. */
export class Room extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === moveRoomPath) return this.letSocketsGo();
    const [, , , room, role] = pathname.split("/");
    return role === "host" ? this.acceptMac(room) : this.acceptPhone(request.headers.get("CF-Connecting-IP") ?? "");
  }

  /** A room's object from before `roomObjectName` closes what it still holds, so its Mac connects again into
   * the room's new object (`moveRoomPath`). */
  private letSocketsGo(): Response {
    for (const ws of this.ctx.getWebSockets()) {
      const state = stateOf(ws);
      if (state && !state.closed) closeSocket(ws, state, 1012, "the room moved");
    }
    return new Response(null, { status: 204 });
  }

  private async acceptMac(room: string): Promise<Response> {
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["mac"]);
    const nonce = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
    const state: MacState = {
      role: "mac",
      room,
      nonce,
      deadline: Date.now() + AUTH_TIMEOUT_MS,
      ready: false,
      closed: false,
      next: 1,
      pushWindowStart: 0,
      pushCount: 0,
    };
    server.serializeAttachment(state);
    server.send(JSON.stringify({ t: "challenge", nonce }));
    await this.scheduleAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  private async acceptPhone(address: string): Promise<Response> {
    const mac = this.readyMac();
    if (!mac) return new Response("no Mac holds this room", { status: 404 });
    const phones = this.phones();
    if (phones.filter((phone) => isAnswered(phone.state)).length >= MAX_PHONES) {
      return new Response("room is full", { status: 429 });
    }
    // Sockets the Mac has not answered cannot keep a phone out: the oldest of them gives way.
    const waiting = phones.filter((phone) => !isAnswered(phone.state)).sort((a, b) => (a.state.openedAt ?? 0) - (b.state.openedAt ?? 0));
    const sameAddress = waiting.filter((phone) => phone.state.address === address);
    if (sameAddress.length >= MAX_WAITING_PER_ADDRESS) {
      const oldest = sameAddress[0];
      this.dropPhone(oldest.ws, oldest.state, 4503, "too many waiting connections");
      waiting.splice(waiting.indexOf(oldest), 1);
    }
    if (waiting.length >= MAX_WAITING_PHONES) this.dropPhone(waiting[0].ws, waiting[0].state, 4503, "too many waiting connections");
    const c = mac.state.next;
    mac.state.next += 1;
    mac.ws.serializeAttachment(mac.state);
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["phone", `c${c}`]);
    const now = Date.now();
    server.serializeAttachment({
      role: "phone",
      c,
      lastFrame: now,
      closed: false,
      answered: false,
      openedAt: now,
      address,
    } satisfies PhoneState);
    trySend(mac.ws, JSON.stringify({ t: "open", c }));
    await this.scheduleAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const state = stateOf(ws);
    if (!state || state.closed) return;
    if (state.role === "phone") return this.fromPhone(ws, state, message);
    if (!state.ready) return this.authenticate(ws, state, message);
    return this.fromMac(ws, state, message);
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    this.left(ws, code);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.left(ws, 1006);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const state = stateOf(ws);
      if (!state || state.closed) continue;
      if (state.role === "mac" && !state.ready && state.deadline <= now) {
        closeSocket(ws, state, 4408, "no auth in time");
      } else if (state.role === "phone" && state.lastFrame + PHONE_IDLE_MS <= now) {
        this.dropPhone(ws, state, 4408, "idle");
      } else if (state.role === "phone" && !isAnswered(state) && (state.openedAt ?? 0) + PHONE_ANSWER_MS <= now) {
        this.dropPhone(ws, state, 4408, "no answer from the Mac");
      }
    }
    await this.scheduleAlarm();
  }

  private fromPhone(ws: WebSocket, state: PhoneState, message: string | ArrayBuffer): void {
    if (typeof message === "string") return this.dropPhone(ws, state, 1003, "binary frames only");
    if (message.byteLength > MAX_PHONE_FRAME) return this.dropPhone(ws, state, 1009, "frame too large");
    const mac = this.readyMac();
    if (!mac) return closeSocket(ws, state, 4404, "the Mac left");
    state.lastFrame = Date.now();
    ws.serializeAttachment(state);
    const frame = new Uint8Array(4 + message.byteLength);
    new DataView(frame.buffer).setUint32(0, state.c);
    frame.set(new Uint8Array(message), 4);
    trySend(mac.ws, frame);
  }

  private async authenticate(ws: WebSocket, state: MacState, message: string | ArrayBuffer): Promise<void> {
    const auth = typeof message === "string" ? parseObject(message) : null;
    if (auth?.t !== "auth" || typeof auth.key !== "string" || typeof auth.sig !== "string") {
      return closeSocket(ws, state, 4401, "authentication failed");
    }
    const valid = await verifyHostAuth(state.room, state.nonce, auth.key, auth.sig);
    // Other events may have run while verifying.
    const current = stateOf(ws);
    if (current?.role !== "mac" || current.closed || current.ready) return;
    if (!valid) return closeSocket(ws, current, 4401, "authentication failed");

    const previous = this.readyMac();
    if (previous) {
      current.next = Math.max(current.next, previous.state.next);
      current.pushWindowStart = previous.state.pushWindowStart;
      current.pushCount = previous.state.pushCount;
      closeSocket(previous.ws, previous.state, 4409, "replaced by a newer connection");
      for (const phone of this.phones()) closeSocket(phone.ws, phone.state, 4409, "the Mac reconnected");
    }
    current.ready = true;
    ws.serializeAttachment(current);
    ws.send(JSON.stringify({ t: "ready" }));
    await this.scheduleAlarm();
  }

  private async fromMac(ws: WebSocket, state: MacState, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") {
      if (message.byteLength < 4) return;
      const phone = this.phone(new DataView(message).getUint32(0));
      if (!phone) return;
      if (!isAnswered(phone.state)) {
        phone.state.answered = true;
        phone.ws.serializeAttachment(phone.state);
      }
      trySend(phone.ws, new Uint8Array(message, 4));
      return;
    }
    const control = parseObject(message);
    if (control?.t === "close" && typeof control.c === "number") {
      const phone = this.phone(control.c);
      if (phone) closeSocket(phone.ws, phone.state, typeof control.code === "number" ? control.code : 1000, "");
    } else if (control?.t === "push" && typeof control.id === "string") {
      const error = await this.push(ws, state, control);
      const reply = error ? { t: "pushed", id: control.id, ok: false, error } : { t: "pushed", id: control.id, ok: true };
      trySend(ws, JSON.stringify(reply));
    }
  }

  private async push(ws: WebSocket, state: MacState, message: Record<string, unknown>): Promise<PushError | null> {
    const push = parsePush(message);
    if (!push) return "invalid";
    const send = pushSender(this.env, push);
    if (!send) return "notConfigured";
    const now = Date.now();
    if (now - state.pushWindowStart >= PUSH_WINDOW_MS) {
      state.pushWindowStart = now;
      state.pushCount = 0;
    }
    if (state.pushCount >= PUSH_LIMIT) return "rateLimited";
    state.pushCount += 1;
    ws.serializeAttachment(state);
    return send();
  }

  private left(ws: WebSocket, code: number): void {
    const state = stateOf(ws);
    if (!state || state.closed) return;
    state.closed = true;
    if (state.role === "phone") {
      const mac = this.readyMac();
      if (mac) trySend(mac.ws, JSON.stringify({ t: "closed", c: state.c, code }));
    } else if (state.ready) {
      for (const phone of this.phones()) closeSocket(phone.ws, phone.state, 4404, "the Mac left");
    }
  }

  /** Closes a phone the relay drops itself and tells the Mac. */
  private dropPhone(ws: WebSocket, state: PhoneState, code: number, reason: string): void {
    closeSocket(ws, state, code, reason);
    const mac = this.readyMac();
    if (mac) trySend(mac.ws, JSON.stringify({ t: "closed", c: state.c, code }));
  }

  private readyMac(): Held<MacState> | undefined {
    for (const ws of this.ctx.getWebSockets("mac")) {
      const state = stateOf(ws);
      if (state?.role === "mac" && state.ready && !state.closed) return { ws, state };
    }
    return undefined;
  }

  private phones(): Held<PhoneState>[] {
    const phones: Held<PhoneState>[] = [];
    for (const ws of this.ctx.getWebSockets("phone")) {
      const state = stateOf(ws);
      if (state?.role === "phone" && !state.closed) phones.push({ ws, state });
    }
    return phones;
  }

  private phone(c: number): Held<PhoneState> | undefined {
    for (const ws of this.ctx.getWebSockets(`c${c}`)) {
      const state = stateOf(ws);
      if (state?.role === "phone" && !state.closed) return { ws, state };
    }
    return undefined;
  }

  /** Wakes the room at the next auth deadline or phone idle limit. */
  private async scheduleAlarm(): Promise<void> {
    let next = Number.POSITIVE_INFINITY;
    for (const ws of this.ctx.getWebSockets()) {
      const state = stateOf(ws);
      if (!state || state.closed) continue;
      if (state.role === "mac" && !state.ready) next = Math.min(next, state.deadline);
      if (state.role === "phone") next = Math.min(next, state.lastFrame + PHONE_IDLE_MS);
      if (state.role === "phone" && !isAnswered(state)) next = Math.min(next, (state.openedAt ?? 0) + PHONE_ANSWER_MS);
    }
    if (Number.isFinite(next)) await this.ctx.storage.setAlarm(next);
    else await this.ctx.storage.deleteAlarm();
  }
}

/** Sends `push` through its provider; null when the relay has no credentials for that provider. */
function pushSender(env: Env, push: Push): (() => Promise<PushError | null>) | null {
  if (push.provider === "fcm") {
    const credentials = fcmCredentials(env);
    return credentials && (() => sendFcmPush(credentials, push));
  }
  const credentials = apnsCredentials(env);
  return credentials && (() => sendApnsPush(credentials, push));
}

function isAnswered(state: PhoneState): boolean {
  return state.answered !== false;
}

function stateOf(ws: WebSocket): SocketState | null {
  return ws.deserializeAttachment() as SocketState | null;
}

function closeSocket(ws: WebSocket, state: SocketState, code: number, reason: string): void {
  state.closed = true;
  ws.serializeAttachment(state);
  try {
    ws.close(code, reason);
  } catch {
    ws.close(1000, reason);
  }
}

function trySend(ws: WebSocket, message: string | Uint8Array): void {
  try {
    ws.send(message);
  } catch {
    // The socket closed meanwhile.
  }
}

function parseObject(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}
