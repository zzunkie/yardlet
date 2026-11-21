import type { ApiResult } from "./account";
import { isPushProvider, type PushProvider } from "./fcm";
import type { Room } from "./room";

/** A push target: 32 random bytes, base64url. */
export const PUSH_TARGET = /^[A-Za-z0-9_-]{43}$/;
const MAX_TOKEN = 4096;
const MAX_BODY = 8192;

/** §14.5: a phone binds its push token to the room `name` (POST) or ends a target it was given (DELETE). */
export async function handlePushTargets(request: Request, name: string, room: DurableObjectStub<Room>): Promise<Response> {
  const text = await readText(request);
  if (text === null) return json({ status: 413, body: { error: "tooLarge" } });
  const body = parseObject(text);
  if (request.method === "DELETE") {
    if (typeof body?.target !== "string" || !PUSH_TARGET.test(body.target)) return json(badRequest);
    await room.removePushTarget(body.target);
    return new Response(null, { status: 204 });
  }
  const provider = body?.provider;
  const token = body?.token;
  const held = body?.target;
  if (!isPushProvider(provider) || !isPushToken(provider, token)) return json(badRequest);
  if (held !== undefined && (typeof held !== "string" || !PUSH_TARGET.test(held))) return json(badRequest);
  return json(await room.registerPushTarget(name, provider, provider === "fcm" ? token : token.toLowerCase(), held));
}

const badRequest: ApiResult = { status: 400, body: { error: "badRequest" } };

/** A token as its service writes it: an FCM registration token, or APNs' device token in hex. */
function isPushToken(provider: PushProvider, token: unknown): token is string {
  if (typeof token !== "string" || token.length > MAX_TOKEN) return false;
  return provider === "fcm" ? /^[\x21-\x7e]+$/.test(token) : /^[0-9a-f]+$/i.test(token);
}

/** The body as text, read no further than `MAX_BODY` bytes; null past that. */
async function readText(request: Request): Promise<string | null> {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (let read = await reader.read(); !read.done; read = await reader.read()) {
    size += read.value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    chunks.push(read.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function parseObject(text: string): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(text);
    return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function json(result: ApiResult): Response {
  return Response.json(result.body, { status: result.status });
}
