import { DurableObject } from "cloudflare:workers";
import { EmailMessage } from "cloudflare:email";

/** `POST /v1/feedback`: what a person writes in the app's Feedback window, forwarded once by email to the team's
 * inbox (relay/README.md, "Feedback"). Nothing of it is stored or logged; a submission's object keeps only whether
 * its id is being sent or was sent, for about 7 days. */

const MAX_BODY = 16 * 1024;
const MAX_MESSAGE = 4000;
const MAX_REPLY_TO = 254;
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** An address for Reply-To: one `@`, a dotted domain, and nothing a header could break on. */
const ADDRESS = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:".]+$/;
/** Control characters; the message may hold line breaks and tabs. */
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
const MESSAGE_CONTROL = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/;
/** How long a submission's id is remembered, and how long a send may run before another try may take over. */
const REMEMBER_MS = 7 * 24 * 60 * 60_000;
const SENDING_MS = 5 * 60_000;
/** What a client is told to wait after a rate limit; the limiter's period. */
const RETRY_AFTER_S = 60;

type Kind = "feedback" | "problem";

export interface Feedback {
  id: string;
  kind: Kind;
  message: string;
  replyTo?: string;
  context: {
    app: string;
    surface: string;
    macOS?: string;
    harness?: string;
    error?: { kind: string; code?: string };
  };
}

export async function handleFeedback(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } });
  const type = request.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
  if (type !== "application/json") return reply(415, "unsupportedMediaType");
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > MAX_BODY) return reply(413, "tooLarge");
  const text = await readLimited(request, MAX_BODY);
  if (text === null) return reply(413, "tooLarge");
  const feedback = parseFeedback(text);
  if (!feedback) return reply(400, "malformed");

  const from = env.FEEDBACK_FROM;
  const to = env.FEEDBACK_TO;
  if (!env.FEEDBACK_MAIL || !from || !to) return reply(503, "notConfigured");

  // The address is the limiter's key and nothing else: the Rate Limiting binding keeps its counters in memory at
  // the Cloudflare location and stores no key.
  const address = request.headers.get("cf-connecting-ip") ?? "";
  for (const [limiter, key] of [[env.FEEDBACK_LIMIT, address], [env.FEEDBACK_GLOBAL_LIMIT, "all"]] as const) {
    if (limiter && !(await limiter.limit({ key })).success) {
      return Response.json({ status: "rateLimited" }, { status: 429, headers: { "retry-after": String(RETRY_AFTER_S), ...noStore } });
    }
  }

  const submission = env.FEEDBACK.get(env.FEEDBACK.idFromName(feedback.id));
  const claim = await submission.claim();
  if (claim === "sent") return reply(202, "accepted");
  if (claim === "inProgress") return reply(409, "inProgress");
  try {
    await env.FEEDBACK_MAIL.send(new EmailMessage(from, to, mailText(feedback, from, to)));
  } catch (error) {
    await submission.release();
    console.error(`feedback mail failed: ${error instanceof Error ? error.name : "error"}`);
    return reply(503, "unavailable");
  }
  await submission.finish();
  return reply(202, "accepted");
}

/** One submission id: whether it is being sent or was sent. */
export class FeedbackSubmission extends DurableObject<Env> {
  /** "send" when this call may send the mail; the object then remembers it is sending until `finish` or `release`. */
  async claim(): Promise<"send" | "sent" | "inProgress"> {
    const now = Date.now();
    const status = await this.ctx.storage.get<string>("status");
    if (status === "sent") return "sent";
    const since = await this.ctx.storage.get<number>("since");
    if (status === "sending" && since !== undefined && now - since < SENDING_MS) return "inProgress";
    await this.ctx.storage.put({ status: "sending", since: now });
    await this.ctx.storage.setAlarm(now + REMEMBER_MS);
    return "send";
  }

  async finish(): Promise<void> {
    await this.ctx.storage.put("status", "sent");
  }

  /** The mail failed: a retry with the same id sends. */
  async release(): Promise<void> {
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

/** The submission when `text` is one the contract allows (relay/README.md, "Feedback"); null otherwise. */
export function parseFeedback(text: string): Feedback | null {
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isObject(body) || !onlyKeys(body, ["id", "kind", "message", "replyTo", "context"])) return null;
  const { id, kind, message, replyTo, context } = body;
  if (typeof id !== "string" || !ID.test(id)) return null;
  if (kind !== "feedback" && kind !== "problem") return null;
  if (typeof message !== "string" || MESSAGE_CONTROL.test(message)) return null;
  const trimmed = message.trim();
  const characters = graphemes(trimmed);
  if (characters < 1 || characters > MAX_MESSAGE) return null;
  if (replyTo !== undefined && (typeof replyTo !== "string" || replyTo.length > MAX_REPLY_TO)) return null;
  if (!isObject(context) || !onlyKeys(context, ["app", "surface", "macOS", "harness", "error"])) return null;
  const app = field(context.app, 80);
  const surface = field(context.surface, 40);
  const macOS = optionalField(context.macOS, 80);
  const harness = optionalField(context.harness, 40);
  if (app === null || surface === null || macOS === null || harness === null) return null;
  let error: Feedback["context"]["error"];
  if (context.error !== undefined) {
    if (!isObject(context.error) || !onlyKeys(context.error, ["kind", "code"])) return null;
    const errorKind = field(context.error.kind, 60);
    const code = optionalField(context.error.code, 60);
    if (errorKind === null || code === null) return null;
    error = { kind: errorKind, ...(code === undefined ? {} : { code }) };
  }
  const address = typeof replyTo === "string" ? replyTo.trim() : "";
  return {
    id,
    kind,
    message: trimmed,
    // Only a printable US-ASCII address that looks like one becomes Reply-To.
    ...(/^[\x21-\x7e]+$/.test(address) && ADDRESS.test(address) ? { replyTo: address } : {}),
    context: {
      app,
      surface,
      ...(macOS === undefined ? {} : { macOS }),
      ...(harness === undefined ? {} : { harness }),
      ...(error === undefined ? {} : { error }),
    },
  };
}

/** The mail: a plain-text UTF-8 message holding the text, then the context, and nothing else. */
export function mailText(feedback: Feedback, from: string, to: string): string {
  const context = feedback.context;
  const lines = [
    `Kind: ${feedback.kind === "problem" ? "Problem report" : "Feedback"}`,
    `App: ${context.app}`,
    `Surface: ${context.surface}`,
  ];
  if (context.macOS) lines.push(`macOS: ${context.macOS}`);
  if (context.harness) lines.push(`Harness: ${context.harness}`);
  if (context.error) lines.push(`Error: ${context.error.kind}${context.error.code ? ` (${context.error.code})` : ""}`);
  const body = `${feedback.message}\n\n--\n${lines.join("\n")}\n`.replace(/\r?\n/g, "\r\n");
  const subject = `${feedback.kind === "problem" ? "Yardlet problem report" : "Yardlet feedback"} ${context.app}`;
  const domain = from.slice(from.lastIndexOf("@") + 1);
  const headers = [
    `From: Yardlet <${from}>`,
    `To: <${to}>`,
    ...(feedback.replyTo ? [`Reply-To: <${feedback.replyTo}>`] : []),
    `Subject: ${encodedWord(subject)}`,
    `Date: ${new Date().toUTCString().replace("GMT", "+0000")}`,
    // One id per submission, so a mail client also folds a copy that somehow arrives twice.
    `Message-ID: <${feedback.id}@${domain}>`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64",
  ];
  return `${headers.join("\r\n")}\r\n\r\n${base64(body).replace(/.{1,76}/g, "$&\r\n")}`;
}

function encodedWord(text: string): string {
  return /^[\x20-\x7e]*$/.test(text) ? text : `=?UTF-8?B?${base64(text)}?=`;
}

function base64(text: string): string {
  let binary = "";
  for (const byte of new TextEncoder().encode(text)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** The body as text when it holds at most `max` bytes; null when it holds more. */
async function readLimited(request: Request, max: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function field(value: unknown, max: number): string | null {
  return typeof value === "string" && graphemes(value) <= max && !CONTROL.test(value) ? value : null;
}

/** undefined when absent, null when present but not allowed. */
function optionalField(value: unknown, max: number): string | null | undefined {
  return value === undefined ? undefined : field(value, max);
}

/** Characters as the app counts them (Swift's `String.count`). */
function graphemes(text: string): number {
  let n = 0;
  for (const _ of new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)) n += 1;
  return n;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function onlyKeys(object: Record<string, unknown>, allowed: string[]): boolean {
  return Object.keys(object).every((key) => allowed.includes(key));
}

const noStore = { "cache-control": "no-store" };

function reply(status: number, value: string): Response {
  return Response.json({ status: value }, { status, headers: noStore });
}
