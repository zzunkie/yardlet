import { base64UrlJson, pemBody, type Push, type PushError } from "./fcm";
import { toBase64Url } from "./keys";

/** Apple takes a new provider token at most every 20 minutes and refuses one older than 60. */
const TOKEN_LIFETIME_MS = 50 * 60_000;
const encoder = new TextEncoder();

export interface ApnsCredentials {
  /** The `.p8` key's PKCS#8 PEM text. */
  key: string;
  keyId: string;
  teamId: string;
  /** The app's bundle ID. */
  topic: string;
}

export function apnsCredentials(env: Env): ApnsCredentials | null {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) return null;
  return { key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC };
}

// One provider token per isolate, reused for 50 minutes; null when the key cannot sign.
let cachedToken: { keyId: string; teamId: string; token: Promise<string | null>; expires: number } | undefined;

function providerToken(credentials: ApnsCredentials): Promise<string | null> {
  const cached = cachedToken;
  if (cached?.keyId === credentials.keyId && cached.teamId === credentials.teamId && Date.now() < cached.expires) {
    return cached.token;
  }
  const entry = {
    keyId: credentials.keyId,
    teamId: credentials.teamId,
    token: signProviderToken(credentials),
    expires: Date.now() + TOKEN_LIFETIME_MS,
  };
  entry.token.then((token) => {
    if (token === null && cachedToken === entry) cachedToken = undefined;
  });
  cachedToken = entry;
  return entry.token;
}

async function signProviderToken(credentials: ApnsCredentials): Promise<string | null> {
  try {
    const key = await crypto.subtle.importKey(
      "pkcs8",
      pemBody(credentials.key),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    const header = base64UrlJson({ alg: "ES256", kid: credentials.keyId });
    const claims = base64UrlJson({ iss: credentials.teamId, iat: Math.floor(Date.now() / 1000) });
    // WebCrypto's ECDSA signature is already r ‖ s, the form JWS takes.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${header}.${claims}`));
    return `${header}.${claims}.${toBase64Url(new Uint8Array(signature))}`;
  } catch {
    return null;
  }
}

/**
 * Sends `push.data` through APNs beside `aps`; null when APNs accepted it. An urgent push is an alert the app's
 * Notification Service Extension opens and rewrites (the loc keys are the app's own words for when it cannot); any
 * other is a background push.
 */
export async function sendApnsPush(credentials: ApnsCredentials, push: Push): Promise<PushError | null> {
  // A device token is hex; anything else names no device.
  if (!/^[0-9a-f]+$/i.test(push.to)) return "unregistered";
  try {
    const token = await providerToken(credentials);
    if (token === null) return "notConfigured";
    const headers: Record<string, string> = {
      authorization: `bearer ${token}`,
      "apns-topic": credentials.topic,
      "apns-push-type": push.urgent ? "alert" : "background",
      "apns-priority": push.urgent ? "10" : "5",
      "content-type": "application/json",
    };
    if (push.ttl !== undefined) {
      headers["apns-expiration"] = String(push.ttl === 0 ? 0 : Math.floor(Date.now() / 1000) + push.ttl);
    }
    if (push.collapse !== undefined) headers["apns-collapse-id"] = push.collapse;
    const aps = push.urgent
      ? {
          alert: { "title-loc-key": "PUSH_FALLBACK_TITLE", "loc-key": "PUSH_FALLBACK_BODY" },
          "mutable-content": 1,
          sound: "default",
        }
      : { "content-available": 1 };
    const host = push.provider === "apns-sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const response = await fetch(`https://${host}/3/device/${push.to}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ ...push.data, aps }),
    });
    if (response.ok) {
      await response.body?.cancel();
      return null;
    }
    const body = (await response.json().catch(() => null)) as { reason?: unknown } | null;
    // Apple's reason is a word from its own list, never the token or the payload.
    const reason = typeof body?.reason === "string" && /^[A-Za-z]{1,64}$/.test(body.reason) ? body.reason : "";
    console.warn("APNs send failed", response.status, reason);
    if (reason === "InvalidProviderToken" || reason === "ExpiredProviderToken") cachedToken = undefined;
    if (response.status === 410) return "unregistered";
    if (response.status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) return "unregistered";
    if (response.status === 429) return "rateLimited";
    if (response.status === 403) return "unavailable";
    if (response.status >= 400 && response.status < 500) return "invalid";
    return "unavailable";
  } catch {
    return "unavailable";
  }
}
