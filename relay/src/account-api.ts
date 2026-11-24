import type { ApiResult } from "./account";
import { fromBase64Url, sha256, toBase64Url } from "./keys";
import { count } from "./metrics";
import {
  accountIdFor,
  authorizeUrl,
  configuredProviders,
  fetchIdentity,
  providerConfig,
  readState,
  signState,
  stateExpiry,
} from "./oauth";

const encoder = new TextEncoder();
const APP_REDIRECT = "yardlet-remote://auth";
const MAX_CLIENT_STATE = 128;
const MAX_DEVICE_NAME = 64;
const CREDENTIAL = /^([a-z2-7]{32})\.([A-Za-z0-9_-]{43})$/;
const CODE_CHALLENGE = /^[A-Za-z0-9_-]{43}$/;
const CODE_VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;
const AUTH_ROUTE = /^\/v1\/auth\/([^/]+)\/(start|callback)$/;
const MAC_ROUTE = /^\/v1\/account\/macs\/([^/]+)$/;

/** Handles §14.4's routes; null for any other path. */
export async function handleAccountRoute(request: Request, env: Env): Promise<Response | null> {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (path === "/v1/auth/providers") {
    return method === "GET" ? json(200, { providers: configuredProviders(env) }) : notAllowed();
  }
  const auth = AUTH_ROUTE.exec(path);
  if (auth) {
    if (method !== "GET") return notAllowed();
    return auth[2] === "start" ? start(env, auth[1], url.searchParams) : callback(env, auth[1], url.searchParams);
  }
  if (path === "/v1/auth/token") return method === "POST" ? redeem(request, env) : notAllowed();
  if (path === "/v1/auth/logout") {
    return method === "POST" ? withToken(request, env, (account, hash) => account.logout(hash)) : notAllowed();
  }
  if (path === "/v1/account") {
    if (method === "GET") return withToken(request, env, (account, hash) => account.getAccount(hash));
    if (method === "DELETE") return withToken(request, env, (account, hash) => account.deleteAccount(hash));
    return notAllowed();
  }
  const link = /^\/v1\/account\/macs\/([a-z2-7]{32})\/link-grants(\/redeem)?$/.exec(path);
  if (link) {
    if (method !== "POST") return notAllowed();
    const room = link[1];
    const body = await request.json<{ clientKey?: string; grant?: string }>().catch(() => null);
    if (typeof body?.clientKey !== "string" || !CODE_CHALLENGE.test(body.clientKey)) return error(400, "badRequest");
    const clientKey = body.clientKey;
    if (link[2]) {
      if (typeof body.grant !== "string" || !CODE_CHALLENGE.test(body.grant)) return error(400, "badRequest");
      const grantHash = await hashSecret(encoder.encode(body.grant));
      return withToken(request, env, (account, hash) => account.redeemLinkGrant(hash, room, clientKey, grantHash));
    }
    const grant = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
    const grantHash = await hashSecret(encoder.encode(grant));
    const issued = await withToken(request, env, (account, hash) => account.issueLinkGrant(hash, room, clientKey, grantHash));
    return issued.ok ? json(200, { grant }) : issued;
  }
  const mac = MAC_ROUTE.exec(path);
  if (mac) {
    const room = mac[1];
    if (method === "PUT") {
      const body = await request.json().catch(() => null);
      return withToken(request, env, (account, hash) => account.putMac(hash, room, body));
    }
    if (method === "DELETE") return withToken(request, env, (account, hash) => account.deleteMac(hash, room));
    return notAllowed();
  }
  return null;
}

async function start(env: Env, provider: string, query: URLSearchParams): Promise<Response> {
  const config = providerConfig(env, provider);
  if (!config) return error(501, "notConfigured");
  const challenge = query.get("code_challenge") ?? "";
  const clientState = query.get("state");
  if (
    query.get("redirect_uri") !== APP_REDIRECT ||
    !CODE_CHALLENGE.test(challenge) ||
    clientState === null ||
    clientState.length > MAX_CLIENT_STATE ||
    (query.has("code_challenge_method") && query.get("code_challenge_method") !== "S256")
  ) {
    return error(400, "badRequest");
  }
  const state = await signState(config.stateSecret, { p: config.provider, c: challenge, s: clientState, e: stateExpiry() });
  return redirect(authorizeUrl(config, state));
}

async function callback(env: Env, provider: string, query: URLSearchParams): Promise<Response> {
  const config = providerConfig(env, provider);
  if (!config) return error(501, "notConfigured");
  const flow = await readState(config.stateSecret, query.get("state") ?? "", config.provider);
  if (!flow) return error(400, "badRequest");
  const back = (fields: Record<string, string>) =>
    redirect(`${APP_REDIRECT}?${new URLSearchParams({ ...fields, state: flow.s })}`);

  const failed = (error: string) => {
    count(env.METRICS, "account.signInFailed", [config.provider, error]);
    return back({ error });
  };
  const providerError = query.get("error");
  if (providerError !== null) return failed(/^[a-z_]{1,64}$/.test(providerError) ? providerError : "providerFailed");
  const code = query.get("code");
  if (!code) return failed("providerFailed");
  const identity = await fetchIdentity(config, code);
  if (!identity) return failed("providerFailed");

  const accountId = await accountIdFor(config.provider, identity.subject);
  const secret = crypto.getRandomValues(new Uint8Array(32));
  await accountStub(env, accountId).createCode({
    hash: await hashSecret(secret),
    challenge: flow.c,
    accountId,
    provider: config.provider,
    name: identity.name,
  });
  return back({ code: `${accountId}.${toBase64Url(secret)}` });
}

async function redeem(request: Request, env: Env): Promise<Response> {
  const body = (await request.json().catch(() => null)) as Record<string, unknown> | null;
  const code = body?.code;
  const verifier = body?.codeVerifier;
  const deviceName = body?.deviceName;
  if (
    typeof code !== "string" ||
    typeof verifier !== "string" ||
    !CODE_VERIFIER.test(verifier) ||
    typeof deviceName !== "string" ||
    deviceName.length > MAX_DEVICE_NAME
  ) {
    return error(400, "badRequest");
  }
  const credential = parseCredential(code);
  if (!credential) return redeemFailed(env);
  const tokenSecret = crypto.getRandomValues(new Uint8Array(32));
  const redeemed = await accountStub(env, credential.accountId).redeemCode({
    hash: await hashSecret(credential.secret),
    challenge: toBase64Url(await sha256(new TextEncoder().encode(verifier))),
    tokenHash: await hashSecret(tokenSecret),
    deviceName,
  });
  if (!redeemed) return redeemFailed(env);
  const { account, created } = redeemed;
  count(env.METRICS, created ? "account.signUp" : "account.signIn", [account.provider]);
  return json(200, { token: `${account.id}.${toBase64Url(tokenSecret)}`, account });
}

/** A code the relay does not take: which provider it came from is not known. */
function redeemFailed(env: Env): Response {
  count(env.METRICS, "account.signInFailed", ["unknown", "invalidCode"]);
  return error(401, "unauthorized");
}

type AccountStub = ReturnType<typeof accountStub>;

async function withToken(
  request: Request,
  env: Env,
  call: (account: AccountStub, tokenHash: string) => Promise<ApiResult>,
): Promise<Response> {
  const header = request.headers.get("authorization") ?? "";
  const credential = header.startsWith("Bearer ") ? parseCredential(header.slice(7)) : null;
  if (!credential) return error(401, "unauthorized");
  const result = await call(accountStub(env, credential.accountId), await hashSecret(credential.secret));
  return result.body === undefined ? new Response(null, { status: result.status }) : json(result.status, result.body);
}

function accountStub(env: Env, accountId: string) {
  return env.ACCOUNT.get(env.ACCOUNT.idFromName(accountId));
}

function parseCredential(text: string): { accountId: string; secret: Uint8Array } | null {
  const match = CREDENTIAL.exec(text);
  const secret = match ? fromBase64Url(match[2]) : null;
  return match && secret?.length === 32 ? { accountId: match[1], secret } : null;
}

async function hashSecret(secret: Uint8Array): Promise<string> {
  return toBase64Url(await sha256(secret));
}

function json(status: number, body: unknown): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
}

function error(status: number, code: string): Response {
  return json(status, { error: code });
}

function notAllowed(): Response {
  return new Response(null, { status: 405 });
}

function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { location, "cache-control": "no-store" } });
}
