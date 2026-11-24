import { count } from "../../src/metrics";

/** The edge Worker (relay/README.md, "Edge Worker"): passes Sparkle's appcast requests on to the site unchanged and
 * counts them by Yardlet version, and answers the download address with a redirect to the release's disk image,
 * counting it by channel and architecture. It stores nothing else and logs nothing. */

export interface EdgeEnv {
  /** Workers Analytics Engine; absent, nothing is counted. */
  METRICS?: AnalyticsEngineDataset;
  /** Where the appcasts are read for the latest release, normally the site itself. */
  FEED_ORIGIN?: string;
  /** GitHub Releases' download base, the one `scripts/release.sh` publishes to. */
  RELEASES?: string;
}

type Arch = "arm64" | "x86_64";

const DEFAULT_FEED_ORIGIN = "https://yardlet.app";
const DEFAULT_RELEASES = "https://github.com/zzunkie/yardlet/releases/download";
/** Each architecture's appcast, named as `scripts/release.sh` names it. */
const FEEDS: Record<string, Arch> = { "/appcast.xml": "arm64", "/appcast-x86_64.xml": "x86_64" };
const DOWNLOAD = /^\/([a-z0-9-]{1,32})\/(arm64|x86_64)(?:\/(\d{1,4}\.\d{1,4}\.\d{1,4}))?\/?$/;
/** Where download links are placed; any other name still downloads and counts as "other". */
const CHANNELS = new Set(["site", "readme", "homebrew", "github", "docs"]);
const EDGE_AGENT = "yardlet-edge";
/** Crawlers, link previews and scripted fetchers that are not someone downloading. Homebrew and curl count. */
const BOT =
  /bot\b|bot\/|crawl|spider|slurp|preview|facebookexternalhit|embedly|headless|python-|go-http-client|scrapy|ahrefs|semrush|lighthouse|pingdom|uptime|monitor/i;

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    // The feeds only on the site's own host: anywhere else there is no origin to pass them to.
    const feed = url.hostname === new URL(env.FEED_ORIGIN ?? DEFAULT_FEED_ORIGIN).hostname ? FEEDS[url.pathname] : undefined;
    if (feed) return passFeed(request, env, feed);
    if (request.method !== "GET" && request.method !== "HEAD") return new Response(null, { status: 405, headers: { allow: "GET, HEAD" } });
    if (url.pathname === "/") return redirect(`${env.FEED_ORIGIN ?? DEFAULT_FEED_ORIGIN}/`);
    const match = DOWNLOAD.exec(url.pathname);
    if (!match) return new Response("not found", { status: 404 });
    const [, name, arch, version] = match;
    const channel = CHANNELS.has(name) ? name : "other";
    const target = version ? pinnedImage(env, arch as Arch, version) : await latestImage(env, arch as Arch);
    if (request.method === "GET" && !isBot(request.headers.get("user-agent"))) {
      count(env.METRICS, "download", [channel, arch, version ? "pinned" : "latest"]);
    }
    return redirect(target);
  },
} satisfies ExportedHandler<EdgeEnv>;

/** The site answers the appcast as it does today; a check from Yardlet counts once under its version. */
async function passFeed(request: Request, env: EdgeEnv, arch: Arch): Promise<Response> {
  const response = await fetch(request);
  const version = request.method === "GET" && response.status < 400 ? yardletVersion(request.headers.get("user-agent")) : null;
  if (version) count(env.METRICS, "update.check", [version, arch]);
  return response;
}

/** The Yardlet version in Sparkle's user agent ("Yardlet/0.11.16 Sparkle/2.10.1"); null for anything else. */
export function yardletVersion(agent: string | null): string | null {
  const match = /(?:^|\s)Yardlet\/(\S+)/.exec(agent ?? "");
  if (!match) return null;
  return /^\d{1,4}(?:\.\d{1,4}){1,3}$/.test(match[1]) ? match[1] : "other";
}

export function isBot(agent: string | null): boolean {
  return !agent || BOT.test(agent);
}

function pinnedImage(env: EdgeEnv, arch: Arch, version: string): string {
  return `${releases(env)}/v${version}/Yardlet-${version}${arch === "arm64" ? "" : `-${arch}`}.dmg`;
}

/** The newest image the architecture's appcast offers, or the latest release's page when it cannot be read. */
async function latestImage(env: EdgeEnv, arch: Arch): Promise<string> {
  const base = releases(env);
  const fallback = `${base.replace(/\/download$/, "")}/latest`;
  const path = Object.keys(FEEDS).find((feed) => FEEDS[feed] === arch)!;
  try {
    const response = await fetch(`${env.FEED_ORIGIN ?? DEFAULT_FEED_ORIGIN}${path}`, {
      headers: { "user-agent": EDGE_AGENT },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (!response.ok) return fallback;
    const url = /<enclosure\b[^>]*\surl="([^"]+)"/.exec(await response.text())?.[1];
    if (!url) return fallback;
    // Parsed, so `..` cannot step out of the releases and a query or fragment cannot ride along.
    const parsed = new URL(url);
    return !parsed.search && !parsed.hash && parsed.href.startsWith(`${base}/`) && parsed.href.endsWith(".dmg") ? parsed.href : fallback;
  } catch {
    return fallback;
  }
}

function releases(env: EdgeEnv): string {
  return (env.RELEASES ?? DEFAULT_RELEASES).replace(/\/+$/, "");
}

function redirect(location: string): Response {
  return new Response(null, { status: 302, headers: { location, "cache-control": "no-store" } });
}
