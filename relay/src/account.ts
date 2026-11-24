import { DurableObject } from "cloudflare:workers";
import { fromBase64Url, isRoom, roomForKey, verifyEd25519 } from "./keys";
import { count } from "./metrics";
import type { Provider } from "./oauth";

const CODE_TTL_MS = 2 * 60_000;
const TOKEN_IDLE_MS = 90 * 24 * 60 * 60_000;
const MAX_MACS = 20;
const GRANT_TTL_MS = 60_000;
const MAX_NAME = 64;
const encoder = new TextEncoder();

/** An answer the Worker turns into an HTTP response. */
export interface ApiResult {
  status: number;
  body?: unknown;
}

export interface AccountSummary {
  id: string;
  provider: Provider;
  name: string;
}

const unauthorized: ApiResult = { status: 401, body: { error: "unauthorized" } };
const badRequest: ApiResult = { status: 400, body: { error: "badRequest" } };
const invalidSignature: ApiResult = { status: 403, body: { error: "invalidSignature" } };

/** One account: its Macs, sign-in tokens (hashes only) and pending one-time codes. */
export class Account extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.createTables();
  }

  private createTables(): void {
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS account (id TEXT PRIMARY KEY, provider TEXT NOT NULL, name TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS codes (
        hash TEXT PRIMARY KEY, challenge TEXT NOT NULL, account_id TEXT NOT NULL,
        provider TEXT NOT NULL, name TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS tokens (
        hash TEXT PRIMARY KEY, device_name TEXT NOT NULL, created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS link_grants (
        hash TEXT PRIMARY KEY, issuer TEXT NOT NULL, room TEXT NOT NULL, client_key TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS macs (
        room TEXT PRIMARY KEY, mac_key TEXT NOT NULL, relay_key TEXT NOT NULL, name TEXT NOT NULL,
        updated_at INTEGER NOT NULL);
    `);
  }

  /** Keeps a one-time code from the provider callback for 2 minutes. */
  async createCode(code: { hash: string; challenge: string; accountId: string; provider: Provider; name: string }): Promise<void> {
    const now = Date.now();
    this.ctx.storage.sql.exec("DELETE FROM codes WHERE expires_at <= ?", now);
    this.ctx.storage.sql.exec(
      "INSERT INTO codes (hash, challenge, account_id, provider, name, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
      code.hash,
      code.challenge,
      code.accountId,
      code.provider,
      code.name,
      now + CODE_TTL_MS,
    );
  }

  /** Spends a one-time code; with the right PKCE challenge it becomes a token. `created` when the account is new. */
  async redeemCode(input: {
    hash: string;
    challenge: string;
    tokenHash: string;
    deviceName: string;
  }): Promise<{ account: AccountSummary; created: boolean } | null> {
    const sql = this.ctx.storage.sql;
    const code = sql
      .exec<{ challenge: string; account_id: string; provider: Provider; name: string; expires_at: number }>(
        "SELECT challenge, account_id, provider, name, expires_at FROM codes WHERE hash = ?",
        input.hash,
      )
      .toArray()[0];
    if (!code) return null;
    sql.exec("DELETE FROM codes WHERE hash = ?", input.hash);
    const now = Date.now();
    if (code.expires_at <= now || code.challenge !== input.challenge) return null;
    const created = sql.exec("SELECT 1 FROM account").toArray().length === 0;
    sql.exec(
      "INSERT INTO account (id, provider, name) VALUES (?, ?, ?) ON CONFLICT (id) DO UPDATE SET provider = excluded.provider, name = excluded.name",
      code.account_id,
      code.provider,
      code.name,
    );
    sql.exec(
      "INSERT INTO tokens (hash, device_name, created_at, last_used_at) VALUES (?, ?, ?, ?)",
      input.tokenHash,
      input.deviceName,
      now,
      now,
    );
    return { account: { id: code.account_id, provider: code.provider, name: code.name }, created };
  }

  async getAccount(tokenHash: string): Promise<ApiResult> {
    const account = this.authorize(tokenHash);
    if (!account) return unauthorized;
    const macs = this.ctx.storage.sql
      .exec<{ room: string; mac_key: string; relay_key: string; name: string; updated_at: number }>(
        "SELECT room, mac_key, relay_key, name, updated_at FROM macs ORDER BY updated_at DESC",
      )
      .toArray()
      .map((mac) => ({ room: mac.room, macKey: mac.mac_key, relayKey: mac.relay_key, name: mac.name, updatedAt: mac.updated_at }));
    return { status: 200, body: { ...account, macs } };
  }

  async putMac(tokenHash: string, room: string, body: unknown): Promise<ApiResult> {
    const account = this.authorize(tokenHash);
    if (!account) return unauthorized;
    const { macKey, relayKey, name, sig } = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
    if (
      !isRoom(room) ||
      typeof macKey !== "string" ||
      typeof relayKey !== "string" ||
      typeof name !== "string" ||
      typeof sig !== "string" ||
      name.length > MAX_NAME
    ) {
      return badRequest;
    }
    const macKeyBytes = fromBase64Url(macKey);
    const relayKeyBytes = fromBase64Url(relayKey);
    const signature = fromBase64Url(sig);
    if (macKeyBytes?.length !== 32 || relayKeyBytes?.length !== 32 || signature?.length !== 64) return badRequest;
    if ((await roomForKey(relayKeyBytes)) !== room) return invalidSignature;
    const message = encoder.encode(`yardlet-account-mac/1\n${account.id}\n${room}\n${macKey}\n${name}`);
    if (!(await verifyEd25519(relayKeyBytes, signature, message))) return invalidSignature;

    const sql = this.ctx.storage.sql;
    const known = sql.exec("SELECT 1 FROM macs WHERE room = ?", room).toArray().length > 0;
    const macs = sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM macs").one().n;
    if (!known && macs >= MAX_MACS) return { status: 409, body: { error: "tooMany" } };
    sql.exec(
      `INSERT INTO macs (room, mac_key, relay_key, name, updated_at) VALUES (?, ?, ?, ?, ?)
       ON CONFLICT (room) DO UPDATE SET mac_key = excluded.mac_key, relay_key = excluded.relay_key,
         name = excluded.name, updated_at = excluded.updated_at`,
      room,
      macKey,
      relayKey,
      name,
      Date.now(),
    );
    if (!known) count(this.env.METRICS, "account.mac", ["added"]);
    return { status: 200, body: { ok: true } };
  }

  /** A grant enrolls one Noise key on one registered host of this account. Only its hash is kept. */
  async issueLinkGrant(tokenHash: string, room: string, clientKey: string, grantHash: string): Promise<ApiResult> {
    if (!this.authorize(tokenHash)) return unauthorized;
    const sql = this.ctx.storage.sql;
    if (!sql.exec("SELECT 1 FROM macs WHERE room = ?", room).toArray().length) {
      return { status: 404, body: { error: "unknownMac" } };
    }
    const now = Date.now();
    sql.exec("DELETE FROM link_grants WHERE expires_at <= ? OR (issuer = ? AND room = ?)", now, tokenHash, room);
    sql.exec("INSERT INTO link_grants VALUES (?, ?, ?, ?, ?)", grantHash, tokenHash, room, clientKey, now + GRANT_TTL_MS);
    return { status: 200 };
  }

  /** The host supplies its own room and the peer key authenticated by Noise. Consume atomically. */
  async redeemLinkGrant(tokenHash: string, room: string, clientKey: string, grantHash: string): Promise<ApiResult> {
    if (!this.authorize(tokenHash)) return unauthorized;
    const now = Date.now();
    const used = this.ctx.storage.sql.exec(
      `DELETE FROM link_grants WHERE hash = ? AND room = ? AND client_key = ? AND expires_at > ?
       AND EXISTS (SELECT 1 FROM macs WHERE room = link_grants.room)
       AND EXISTS (SELECT 1 FROM tokens WHERE hash = link_grants.issuer AND last_used_at >= ?)
       RETURNING 1`, grantHash, room, clientKey, now, now - TOKEN_IDLE_MS,
    ).toArray().length;
    return used ? { status: 200, body: { ok: true } } : { status: 403, body: { error: "invalidGrant" } };
  }

  async deleteMac(tokenHash: string, room: string): Promise<ApiResult> {
    if (!this.authorize(tokenHash)) return unauthorized;
    this.ctx.storage.sql.exec("DELETE FROM link_grants WHERE room = ?", room);
    const removed = this.ctx.storage.sql.exec("DELETE FROM macs WHERE room = ? RETURNING 1", room).toArray().length;
    if (removed) count(this.env.METRICS, "account.mac", ["removed"], removed);
    return { status: 204 };
  }

  async logout(tokenHash: string): Promise<ApiResult> {
    if (!this.authorize(tokenHash)) return unauthorized;
    this.ctx.storage.sql.exec("DELETE FROM tokens WHERE hash = ?", tokenHash);
    return { status: 204 };
  }

  async deleteAccount(tokenHash: string): Promise<ApiResult> {
    if (!this.authorize(tokenHash)) return unauthorized;
    const macs = this.ctx.storage.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM macs").one().n;
    await this.ctx.storage.deleteAll();
    if (macs) count(this.env.METRICS, "account.mac", ["removed"], macs);
    count(this.env.METRICS, "account.deleted");
    this.createTables();
    return { status: 204 };
  }

  /** The account when `tokenHash` names a token used within 90 days; marks it used. */
  private authorize(tokenHash: string): AccountSummary | null {
    const sql = this.ctx.storage.sql;
    const token = sql.exec<{ last_used_at: number }>("SELECT last_used_at FROM tokens WHERE hash = ?", tokenHash).toArray()[0];
    if (!token) return null;
    const now = Date.now();
    if (now - token.last_used_at > TOKEN_IDLE_MS) {
      sql.exec("DELETE FROM tokens WHERE hash = ?", tokenHash);
      return null;
    }
    sql.exec("UPDATE tokens SET last_used_at = ? WHERE hash = ?", now, tokenHash);
    return sql.exec<{ id: string; provider: Provider; name: string }>("SELECT id, provider, name FROM account").toArray()[0] ?? null;
  }
}
