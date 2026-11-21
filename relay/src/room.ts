import { DurableObject } from "cloudflare:workers";
import type { ApiResult } from "./account";
import { apnsCredentials, sendApnsPush } from "./apns";
import { fcmCredentials, isPushProvider, parsePush, sendFcmPush, type Push, type PushError, type PushProvider } from "./fcm";
import { toBase64Url, verifyHostAuth } from "./keys";
import { moveRoomPath } from "./placement";
import { PUSH_TARGET } from "./push-targets";

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
/** The push targets a room keeps, and how long one may go unregistered and unpushed (§14.5). */
const MAX_PUSH_TARGETS = 64;
const TARGET_IDLE_MS = 90 * 24 * 60 * 60_000;
/** How often a token is sent its target, and how long that push lives. */
const OFFER_INTERVAL_MS = 30_000;
const OFFER_TTL_S = 300;
/** Until when a push may name an FCM registration token itself rather than a target: Android apps from before
 * targets gave the Mac their token, and the Mac sends what its phone gave it (§14.2). */
export const rawFcmTokensUntil = Date.UTC(2027, 1, 1);

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

/** One Mac's room: forwards frames between its socket and up to 8 phone sockets, and keeps the push targets its
 * phones registered. */
export class Room extends DurableObject<Env> {
  /** The push target table exists. It is made when a phone first registers and dropped with its last target, so a
   * room no phone registered with stores nothing. */
  private hasTargetTable = false;

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
    this.expireTargets(now);
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

  /** Binds a phone's push token to this room (§14.5). A phone naming the target it holds for the token gets it back.
   * Otherwise the relay sends the target to the token itself, as a push only that phone receives and takes only while
   * it registers here, so whoever else knows the token gains nothing by registering it. Only while the room's Mac is
   * here, so nothing is stored for a room no Mac opened. */
  async registerPushTarget(room: string, provider: PushProvider, token: string, held?: string): Promise<ApiResult> {
    const mac = this.readyMac();
    if (!mac) return { status: 404, body: { error: "notFound" } };
    const now = Date.now();
    const sql = this.targets(true)!;
    const bound = sql
      .exec<{ target: string; offered_at: number }>(
        "SELECT target, offered_at FROM push_targets WHERE provider = ? AND token = ?",
        provider,
        token,
      )
      .toArray()[0];
    if (bound && held === bound.target) {
      sql.exec("UPDATE push_targets SET used_at = ? WHERE target = ?", now, bound.target);
      return { status: 200, body: { target: bound.target } };
    }
    if (bound && now - bound.offered_at < OFFER_INTERVAL_MS) return { status: 429, body: { error: "rateLimited" } };
    // Full: a new phone waits rather than ending a target a phone relies on.
    if (!bound && sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM push_targets").one().n >= MAX_PUSH_TARGETS) {
      return { status: 409, body: { error: "tooMany" } };
    }
    const target = bound?.target ?? toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
    // Urgent through FCM, a high-priority data message; through APNs a background push, which shows nothing.
    const send = pushSender(this.env, {
      provider,
      to: token,
      urgent: provider === "fcm",
      ttl: OFFER_TTL_S,
      data: { pushTarget: target, room },
    });
    if (!send) return { status: 501, body: { error: "notConfigured" } };
    if (!this.takePush(mac)) return { status: 429, body: { error: "rateLimited" } };
    if (bound) {
      sql.exec("UPDATE push_targets SET offered_at = ? WHERE target = ?", now, target);
    } else {
      sql.exec(
        "INSERT INTO push_targets (target, provider, token, used_at, offered_at) VALUES (?, ?, ?, ?, ?)",
        target,
        provider,
        token,
        now,
        now,
      );
      await this.scheduleAlarm();
    }
    const error = await send();
    if (!error) return { status: 202, body: { sent: true } };
    // A token the service does not take keeps no target here.
    if (error === "unregistered" || !bound) this.dropTargets("DELETE FROM push_targets WHERE target = ?", target);
    return { status: OFFER_FAILURE_STATUS[error], body: { error } };
  }

  /** Ends a target, whether or not the room's Mac is here (§14.5). */
  async removePushTarget(target: string): Promise<void> {
    this.dropTargets("DELETE FROM push_targets WHERE target = ?", target);
  }

  /** Runs a deletion on the targets, and drops the table once it holds none. */
  private dropTargets(query: string, ...bindings: (string | number)[]): void {
    const sql = this.targets();
    if (!sql) return;
    sql.exec(query, ...bindings);
    if (sql.exec("SELECT 1 FROM push_targets LIMIT 1").toArray().length === 0) {
      sql.exec("DROP TABLE push_targets");
      this.hasTargetTable = false;
    }
  }

  private expireTargets(now: number): void {
    this.dropTargets("DELETE FROM push_targets WHERE used_at <= ?", now - TARGET_IDLE_MS);
  }

  /** The room's push targets, or null while it has none; `create` makes the table. */
  private targets(create = false): SqlStorage | null {
    const sql = this.ctx.storage.sql;
    if (!this.hasTargetTable && create) {
      sql.exec(
        "CREATE TABLE IF NOT EXISTS push_targets (target TEXT PRIMARY KEY, provider TEXT NOT NULL, token TEXT NOT NULL, used_at INTEGER NOT NULL, offered_at INTEGER NOT NULL)",
      );
      this.hasTargetTable = true;
    } else if (!this.hasTargetTable) {
      this.hasTargetTable = sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'push_targets'").toArray().length > 0;
    }
    return this.hasTargetTable ? sql : null;
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
    const requested = parsePush(message);
    if (!requested) return "invalid";
    const push = this.destination(requested);
    if (typeof push === "string") return push;
    const send = pushSender(this.env, push);
    if (!send) return "notConfigured";
    if (!this.takePush({ ws, state })) return "rateLimited";
    const error = await send();
    // The service no longer knows the token: its target goes too.
    if (error === "unregistered" && push.to !== requested.to) {
      this.dropTargets("DELETE FROM push_targets WHERE target = ?", requested.to);
    }
    return error;
  }

  /** Counts a push against the room's limit (§14.2); false when the minute's are spent. */
  private takePush(mac: Held<MacState>): boolean {
    const now = Date.now();
    if (now - mac.state.pushWindowStart >= PUSH_WINDOW_MS) {
      mac.state.pushWindowStart = now;
      mac.state.pushCount = 0;
    }
    if (mac.state.pushCount >= PUSH_LIMIT) return false;
    mac.state.pushCount += 1;
    mac.ws.serializeAttachment(mac.state);
    return true;
  }

  /** Where a push goes: to the token a phone bound to this room under the target the push names (§14.5). */
  private destination(push: Push): Push | PushError {
    if (!PUSH_TARGET.test(push.to)) {
      return push.provider === "fcm" && Date.now() < rawFcmTokensUntil ? push : "unregistered";
    }
    const sql = this.targets();
    const row = sql
      ?.exec<{ provider: string; token: string }>("SELECT provider, token FROM push_targets WHERE target = ?", push.to)
      .toArray()[0];
    if (!sql || !row || !isPushProvider(row.provider)) return "unregistered";
    sql.exec("UPDATE push_targets SET used_at = ? WHERE target = ?", Date.now(), push.to);
    return { ...push, provider: row.provider, to: row.token };
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

  /** Wakes the room at the next auth deadline, phone idle limit or push target expiry. */
  private async scheduleAlarm(): Promise<void> {
    let next = Number.POSITIVE_INFINITY;
    const oldest = this.targets()?.exec<{ used: number | null }>("SELECT MIN(used_at) AS used FROM push_targets").one().used;
    if (oldest != null) next = oldest + TARGET_IDLE_MS;
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

/** The HTTP status a registration answers when sending the target failed. */
const OFFER_FAILURE_STATUS: Record<PushError, number> = {
  unregistered: 410,
  invalid: 400,
  rateLimited: 429,
  unavailable: 503,
  notConfigured: 501,
};

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
