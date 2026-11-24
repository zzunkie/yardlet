import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import { mailText, parseFeedback, type Feedback } from "../src/feedback";
import { count } from "../src/metrics";
import { RELAY, openMac } from "./helpers";

let address = 0;
let send: MockInstance<(message: EmailMessage) => Promise<EmailSendResult>>;

beforeEach(() => {
  // Each test its own client address, so the per-address limit of one test does not reach another.
  address += 1;
  send = vi.spyOn(env.FEEDBACK_MAIL! as { send(message: EmailMessage): Promise<EmailSendResult> }, "send");
  send.mockResolvedValue({ messageId: "message" });
});

afterEach(() => {
  vi.restoreAllMocks();
});

function submission(fields: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: crypto.randomUUID(),
    kind: "feedback",
    message: "The sidebar hides my task.",
    context: { app: "0.11.16 (38)", surface: "home" },
    ...fields,
  };
}

function post(body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return exports.default.fetch(`${RELAY}/v1/feedback`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": `192.0.2.${address}`, ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function status(response: Response): Promise<[number, unknown]> {
  return [response.status, await response.json()];
}

describe("feedback", () => {
  it("sends an accepted submission once, however often its id comes back", async () => {
    const body = submission({ kind: "problem", replyTo: "someone@example.test" });
    expect(await status(await post(body))).toEqual([202, { status: "accepted" }]);
    expect(await status(await post(body))).toEqual([202, { status: "accepted" }]);
    expect(send).toHaveBeenCalledTimes(1);
    const message = send.mock.calls[0][0];
    expect([message.from, message.to]).toEqual(["feedback@relay.example.test", "team@example.test"]);
  });

  it("sends a retry after the mail failed", async () => {
    send.mockRejectedValueOnce(new Error("destination not verified"));
    const body = submission();
    expect(await status(await post(body))).toEqual([503, { status: "unavailable" }]);
    expect(await status(await post(body))).toEqual([202, { status: "accepted" }]);
    expect(send).toHaveBeenCalledTimes(2);
  });

  it("asks a retry to wait while the same id is being sent", async () => {
    const body = submission();
    const id = body.id as string;
    expect(await env.FEEDBACK.get(env.FEEDBACK.idFromName(id)).claim()).toBe("send");
    expect(await status(await post(body))).toEqual([409, { status: "inProgress" }]);
    expect(send).not.toHaveBeenCalled();
  });

  it("refuses what the contract does not allow", async () => {
    const malformed = [
      "{",
      [],
      submission({ id: "ABC" }),
      submission({ id: crypto.randomUUID().toUpperCase() }),
      submission({ kind: "praise" }),
      submission({ message: "   " }),
      submission({ message: "x".repeat(4001) }),
      submission({ replyTo: `${"a".repeat(250)}@example.test` }),
      submission({ replyTo: 7 }),
      submission({ extra: true }),
      submission({ context: { app: "0.11.16 (38)" } }),
      submission({ context: { app: "0.11.16 (38)", surface: "home", account: "me" } }),
      submission({ context: { app: "0.11.16\r\nBcc: x@example.test", surface: "home" } }),
      submission({ context: { app: "0.11.16 (38)", surface: "home", error: { kind: "x", path: "/Users" } } }),
    ];
    for (const body of malformed) expect(await status(await post(body))).toEqual([400, { status: "malformed" }]);
    expect(send).not.toHaveBeenCalled();
  });

  it("refuses a large body, another media type and another method", async () => {
    const large = JSON.stringify(submission({ message: "x".repeat(17 * 1024) }));
    expect(await status(await post(large))).toEqual([413, { status: "tooLarge" }]);
    // A body larger than its Content-Length says is cut off when it is read.
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(large));
        controller.close();
      },
    });
    const streamed = await exports.default.fetch(`${RELAY}/v1/feedback`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: stream,
    });
    expect(await status(streamed)).toEqual([413, { status: "tooLarge" }]);
    expect(await status(await post(submission(), { "content-type": "text/plain" }))).toEqual([
      415,
      { status: "unsupportedMediaType" },
    ]);
    expect((await exports.default.fetch(`${RELAY}/v1/feedback`)).status).toBe(405);
    expect(send).not.toHaveBeenCalled();
  });

  it("limits one address and tells it when to try again", async () => {
    for (let i = 0; i < 5; i++) expect((await post(submission())).status).toBe(202);
    const limited = await post(submission());
    expect(await status(limited)).toEqual([429, { status: "rateLimited" }]);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(send).toHaveBeenCalledTimes(5);
  });
});

describe("feedback mail", () => {
  const feedback: Feedback = {
    id: "00000000-0000-4000-8000-000000000001",
    kind: "problem",
    message: "연결이 끊겼어요.\nAgain.",
    replyTo: "someone@example.test",
    context: { app: "0.11.16 (38)", surface: "remoteTask", macOS: "26.1", harness: "codex", error: { kind: "relay", code: "4404" } },
  };

  function decode(raw: string): { headers: string; body: string } {
    const [headers, body] = raw.split("\r\n\r\n");
    const bytes = Uint8Array.from(atob(body.replace(/\r\n/g, "")), (c) => c.charCodeAt(0));
    return { headers, body: new TextDecoder().decode(bytes) };
  }

  it("holds the message, then the context, and a Reply-To only from a valid address", () => {
    const { headers, body } = decode(mailText(feedback, "feedback@relay.example.test", "team@example.test"));
    expect(headers).toContain("Subject: Yardlet problem report 0.11.16 (38)");
    expect(headers).toContain("Reply-To: <someone@example.test>");
    expect(headers).toContain("Message-ID: <00000000-0000-4000-8000-000000000001@relay.example.test>");
    expect(body).toBe(
      "연결이 끊겼어요.\r\nAgain.\r\n\r\n--\r\nKind: Problem report\r\nApp: 0.11.16 (38)\r\nSurface: remoteTask\r\n" +
        "macOS: 26.1\r\nHarness: codex\r\nError: relay (4404)\r\n",
    );
    const parsed = parseFeedback(JSON.stringify({ ...feedback, replyTo: "not an address" }));
    expect(parsed?.replyTo).toBeUndefined();
    expect(decode(mailText(parsed!, "feedback@relay.example.test", "team@example.test")).headers).not.toContain("Reply-To");
  });

  it("drops a reply address with non-ASCII or control characters and still accepts the note", async () => {
    for (const replyTo of ["사용자@example.test", "someone@exämple.test", "some\u0001one@example.test", "some\u007fone@example.test"]) {
      const parsed = parseFeedback(JSON.stringify({ ...feedback, replyTo }));
      expect(parsed).not.toBeNull();
      expect(parsed?.replyTo).toBeUndefined();
      expect(decode(mailText(parsed!, "feedback@relay.example.test", "team@example.test")).headers).not.toContain("Reply-To");
    }
    const send = vi.spyOn(env.FEEDBACK_MAIL! as { send(message: EmailMessage): Promise<EmailSendResult> }, "send");
    send.mockResolvedValue({ messageId: "message" });
    const body = { id: crypto.randomUUID(), kind: "feedback", message: "Hi", replyTo: "사용자@example.test", context: { app: "0.11.16 (38)", surface: "home" } };
    const response = await exports.default.fetch(`${RELAY}/v1/feedback`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "198.51.100.1" },
      body: JSON.stringify(body),
    });
    expect(response.status).toBe(202);
    expect(send).toHaveBeenCalledTimes(1);
  });
});

describe("counts", () => {
  it("does nothing without a dataset, and a failing write reaches no one", () => {
    expect(() => count(undefined, "relay.host", ["ready"])).not.toThrow();
    const failing = { writeDataPoint: () => { throw new Error("full"); } };
    expect(() => count(failing, "relay.host", ["ready"])).not.toThrow();
  });

  it("counts a Mac that connects, with no room or key among its labels", async () => {
    const write = vi.spyOn(env.METRICS!, "writeDataPoint");
    const { key } = await openMac();
    const points = write.mock.calls.map(([point]) => point);
    expect(points).toContainEqual({ indexes: ["relay.host"], blobs: ["relay.host", "ready"], doubles: [1] });
    expect(JSON.stringify(points)).not.toContain(key.room);
  });
});
