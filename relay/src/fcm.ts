import { toBase64Url } from "./keys";

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const encoder = new TextEncoder();

export type PushError = "unregistered" | "invalid" | "rateLimited" | "unavailable" | "notConfigured";

/** Where a push goes: FCM, or APNs for an iOS build signed for production or for development. */
export type PushProvider = "fcm" | "apns" | "apns-sandbox";
const PROVIDERS: readonly string[] = ["fcm", "apns", "apns-sandbox"] satisfies PushProvider[];

export interface Push {
  provider: PushProvider;
  to: string;
  urgent: boolean;
  collapse?: string;
  ttl?: number;
  data: Record<string, string>;
}

export interface FcmCredentials {
  projectId: string;
  clientEmail: string;
  privateKey: string;
}

class PushFailure extends Error {
  constructor(readonly reason: PushError) {
    super(reason);
  }
}

export function fcmCredentials(env: Env): FcmCredentials | null {
  if (!env.FCM_SERVICE_ACCOUNT || !env.FCM_PROJECT_ID) return null;
  try {
    const account = JSON.parse(env.FCM_SERVICE_ACCOUNT) as { client_email?: unknown; private_key?: unknown };
    if (typeof account.client_email !== "string" || typeof account.private_key !== "string") return null;
    return { projectId: env.FCM_PROJECT_ID, clientEmail: account.client_email, privateKey: account.private_key };
  } catch {
    return null;
  }
}

/** Reads a relay `push` message; null when a field is missing or wrong. No `provider` means FCM. */
export function parsePush(message: Record<string, unknown>): Push | null {
  const { provider = "fcm", to, urgent, collapse, ttl, data } = message;
  if (typeof provider !== "string" || !PROVIDERS.includes(provider)) return null;
  if (typeof to !== "string" || to === "") return null;
  if (urgent !== undefined && typeof urgent !== "boolean") return null;
  if (collapse !== undefined && (typeof collapse !== "string" || encoder.encode(collapse).length > 64)) return null;
  if (ttl !== undefined && (typeof ttl !== "number" || !Number.isInteger(ttl) || ttl < 0)) return null;
  if (typeof data !== "object" || data === null || Array.isArray(data)) return null;
  if (!Object.values(data).every((value) => typeof value === "string")) return null;
  return { provider: provider as PushProvider, to, urgent: urgent === true, collapse, ttl, data: data as Record<string, string> };
}

// One access token per isolate, reused until shortly before it expires.
let cachedToken: { clientEmail: string; token: Promise<string>; expires: number } | undefined;

function accessToken(credentials: FcmCredentials): Promise<string> {
  if (cachedToken?.clientEmail === credentials.clientEmail && Date.now() < cachedToken.expires) {
    return cachedToken.token;
  }
  const entry = { clientEmail: credentials.clientEmail, token: Promise.resolve(""), expires: Number.POSITIVE_INFINITY };
  entry.token = requestAccessToken(credentials).then(
    ({ token, expiresIn }) => {
      entry.expires = Date.now() + Math.max(0, expiresIn - 60) * 1000;
      return token;
    },
    (error: unknown) => {
      if (cachedToken === entry) cachedToken = undefined;
      throw error;
    },
  );
  cachedToken = entry;
  return entry.token;
}

async function requestAccessToken(credentials: FcmCredentials): Promise<{ token: string; expiresIn: number }> {
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "pkcs8",
      pemBody(credentials.privateKey),
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new PushFailure("notConfigured");
  }
  const now = Math.floor(Date.now() / 1000);
  const header = base64UrlJson({ alg: "RS256", typ: "JWT" });
  const claims = base64UrlJson({ iss: credentials.clientEmail, scope: SCOPE, aud: TOKEN_URL, iat: now, exp: now + 3600 });
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(`${header}.${claims}`));
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${toBase64Url(new Uint8Array(signature))}`,
    }),
  });
  const body = (await response.json().catch(() => null)) as { access_token?: unknown; expires_in?: unknown } | null;
  if (!response.ok || typeof body?.access_token !== "string") {
    console.warn("FCM access token request failed", response.status);
    throw new PushFailure("unavailable");
  }
  return { token: body.access_token, expiresIn: typeof body.expires_in === "number" ? body.expires_in : 3600 };
}

/** Sends `push.data` as an FCM HTTP v1 data message; null when FCM accepted it. */
export async function sendFcmPush(credentials: FcmCredentials, push: Push): Promise<PushError | null> {
  try {
    const token = await accessToken(credentials);
    const android: Record<string, string> = { priority: push.urgent ? "HIGH" : "NORMAL" };
    if (push.collapse !== undefined) android.collapse_key = push.collapse;
    if (push.ttl !== undefined) android.ttl = `${push.ttl}s`;
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(credentials.projectId)}/messages:send`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ message: { token: push.to, data: push.data, android } }),
      },
    );
    if (response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = await response.json().catch(() => null);
    console.warn("FCM send failed", response.status);
    if (response.status === 401) cachedToken = undefined;
    if (response.status === 404 || fcmErrorCode(body) === "UNREGISTERED") return "unregistered";
    if (response.status === 400) return "invalid";
    if (response.status === 429) return "rateLimited";
    return "unavailable";
  } catch (error) {
    return error instanceof PushFailure ? error.reason : "unavailable";
  }
}

function fcmErrorCode(body: unknown): string | undefined {
  const details = (body as { error?: { details?: unknown } } | null)?.error?.details;
  if (!Array.isArray(details)) return undefined;
  for (const detail of details) {
    const code = (detail as { errorCode?: unknown } | null)?.errorCode;
    if (typeof code === "string") return code;
  }
  return undefined;
}

export function pemBody(pem: string): Uint8Array {
  const base64 = pem.replace(/-----(BEGIN|END) [A-Z ]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

export function base64UrlJson(value: unknown): string {
  return toBase64Url(encoder.encode(JSON.stringify(value)));
}
