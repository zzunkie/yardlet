import { afterEach, describe, expect, it, vi } from "vitest";
import edge, { isBot, yardletVersion, type EdgeEnv } from "../src/index";

const RELEASES = "https://github.com/zzunkie/yardlet/releases/download";
const SPARKLE = "Yardlet/0.11.16 Sparkle/2.10.1";
const SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15";

function appcast(version: string, suffix = ""): string {
  return `<?xml version="1.0"?><rss><channel><item><title>${version}</title>
    <enclosure url="${RELEASES}/v${version}/Yardlet-${version}${suffix}.dmg" length="1" type="application/octet-stream"/>
  </item></channel></rss>`;
}

/** The site, answering each appcast; returns what it was asked. */
function fakeSite(feeds: Record<string, string> = { "/appcast.xml": appcast("0.11.16"), "/appcast-x86_64.xml": appcast("0.11.16", "-x86_64") }) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    const body = feeds[new URL(request.url).pathname];
    return body ? new Response(body, { headers: { "content-type": "application/xml", etag: '"feed"' } }) : new Response("missing", { status: 404 });
  });
}

function metrics() {
  const points: AnalyticsEngineDataPoint[] = [];
  return { points, dataset: { writeDataPoint: (point?: AnalyticsEngineDataPoint) => void points.push(point!) } };
}

function call(env: EdgeEnv, url: string, init: RequestInit = {}): Promise<Response> {
  return edge.fetch(new Request(url, init) as Request<unknown, IncomingRequestCfProperties>, env);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("user agents", () => {
  it("reads Yardlet's version from Sparkle's user agent", () => {
    expect(yardletVersion(SPARKLE)).toBe("0.11.16");
    expect(yardletVersion("Yardlet/1.0 Sparkle/2.10.1")).toBe("1.0");
    expect(yardletVersion("Yardlet/<script> Sparkle/2.10.1")).toBe("other");
    expect(yardletVersion(SAFARI)).toBeNull();
    expect(yardletVersion("yardlet-edge")).toBeNull();
    expect(yardletVersion(null)).toBeNull();
  });

  it("tells crawlers and previews from people and Homebrew", () => {
    for (const agent of [null, "", "Googlebot/2.1 (+http://www.google.com/bot.html)", "Slackbot-LinkExpanding 1.0", "facebookexternalhit/1.1", "python-requests/2.32"]) {
      expect(isBot(agent)).toBe(true);
    }
    for (const agent of [SAFARI, "Homebrew/4.6.0 (Macintosh; arm64 Mac OS X 26.1) curl/8.7.1", "curl/8.7.1"]) {
      expect(isBot(agent)).toBe(false);
    }
  });
});

describe("appcast", () => {
  it("passes the appcast on unchanged and counts a check by version and architecture", async () => {
    const site = fakeSite();
    const { points, dataset } = metrics();
    const response = await call({ METRICS: dataset }, "https://yardlet.app/appcast-x86_64.xml", { headers: { "user-agent": SPARKLE } });
    expect(response.status).toBe(200);
    expect(response.headers.get("etag")).toBe('"feed"');
    expect(await response.text()).toBe(appcast("0.11.16", "-x86_64"));
    expect(new Request(site.mock.calls[0][0]).url).toBe("https://yardlet.app/appcast-x86_64.xml");
    expect(points).toEqual([{ indexes: ["update.check"], blobs: ["update.check", "0.11.16", "x86_64"], doubles: [1] }]);
  });

  it("counts nothing for a browser, a HEAD request or a missing dataset", async () => {
    fakeSite();
    const { points, dataset } = metrics();
    await call({ METRICS: dataset }, "https://yardlet.app/appcast.xml", { headers: { "user-agent": SAFARI } });
    await call({ METRICS: dataset }, "https://yardlet.app/appcast.xml", { method: "HEAD", headers: { "user-agent": SPARKLE } });
    expect(points).toEqual([]);
    expect((await call({}, "https://yardlet.app/appcast.xml", { headers: { "user-agent": SPARKLE } })).status).toBe(200);
  });
});

describe("downloads", () => {
  it("redirects to the newest image for the architecture and counts the channel", async () => {
    fakeSite();
    const { points, dataset } = metrics();
    const env = { METRICS: dataset, RELEASES, FEED_ORIGIN: "https://yardlet.app" };
    const arm = await call(env, "https://dl.yardlet.app/site/arm64", { headers: { "user-agent": SAFARI } });
    expect(arm.status).toBe(302);
    expect(arm.headers.get("location")).toBe(`${RELEASES}/v0.11.16/Yardlet-0.11.16.dmg`);
    const intel = await call(env, "https://dl.yardlet.app/somewhere/x86_64", { headers: { "user-agent": SAFARI } });
    expect(intel.headers.get("location")).toBe(`${RELEASES}/v0.11.16/Yardlet-0.11.16-x86_64.dmg`);
    expect(points.map((point) => point.blobs)).toEqual([
      ["download", "site", "arm64", "latest"],
      ["download", "other", "x86_64", "latest"],
    ]);
  });

  it("redirects a pinned version without reading the appcast", async () => {
    const site = fakeSite();
    const { points, dataset } = metrics();
    const response = await call({ METRICS: dataset }, "https://dl.yardlet.app/homebrew/x86_64/0.11.15", {
      headers: { "user-agent": "Homebrew/4.6.0 curl/8.7.1" },
    });
    expect(response.headers.get("location")).toBe(`${RELEASES}/v0.11.15/Yardlet-0.11.15-x86_64.dmg`);
    expect(site).not.toHaveBeenCalled();
    expect(points.map((point) => point.blobs)).toEqual([["download", "homebrew", "x86_64", "pinned"]]);
  });

  it("still redirects crawlers and HEAD requests but does not count them", async () => {
    fakeSite();
    const { points, dataset } = metrics();
    expect((await call({ METRICS: dataset }, "https://dl.yardlet.app/site/arm64", { headers: { "user-agent": "Googlebot/2.1" } })).status).toBe(302);
    expect((await call({ METRICS: dataset }, "https://dl.yardlet.app/site/arm64", { method: "HEAD", headers: { "user-agent": SAFARI } })).status).toBe(302);
    expect(points).toEqual([]);
  });

  it("falls back to the latest release when the appcast offers no image from the releases", async () => {
    fakeSite({ "/appcast.xml": appcast("0.11.16").replace(RELEASES, "https://elsewhere.example.test") });
    const response = await call({}, "https://dl.yardlet.app/site/arm64", { headers: { "user-agent": SAFARI } });
    expect(response.headers.get("location")).toBe("https://github.com/zzunkie/yardlet/releases/latest");
    const missing = await call({}, "https://dl.yardlet.app/site/x86_64", { headers: { "user-agent": SAFARI } });
    expect(missing.headers.get("location")).toBe("https://github.com/zzunkie/yardlet/releases/latest");
  });

  it("falls back for an enclosure that steps out of the releases or carries a query", async () => {
    for (const url of [
      `${RELEASES}/../../other/releases/download/v1.0.0/Yardlet-1.0.0.dmg`,
      `${RELEASES}/v0.11.16/Yardlet-0.11.16.dmg?x=1.dmg`,
      `${RELEASES}/v0.11.16/Yardlet-0.11.16.dmg#.dmg`,
    ]) {
      vi.restoreAllMocks();
      fakeSite({ "/appcast.xml": `<rss><channel><item><enclosure url="${url}" length="1"/></item></channel></rss>` });
      const response = await call({}, "https://dl.yardlet.app/site/arm64", { headers: { "user-agent": SAFARI } });
      expect(response.headers.get("location")).toBe("https://github.com/zzunkie/yardlet/releases/latest");
    }
  });

  it("answers unknown paths and methods", async () => {
    const site = fakeSite();
    expect((await call({}, "https://dl.yardlet.app/appcast.xml", { headers: { "user-agent": SPARKLE } })).status).toBe(404);
    expect(site).not.toHaveBeenCalled();
    expect((await call({}, "https://dl.yardlet.app/site/ppc")).status).toBe(404);
    expect((await call({}, "https://dl.yardlet.app/site/arm64", { method: "POST" })).status).toBe(405);
    expect((await call({}, "https://dl.yardlet.app/")).headers.get("location")).toBe("https://yardlet.app/");
  });
});
