import { count } from "../../src/metrics";

/** The edge Worker (relay/README.md, "Edge Worker"): passes site HTML pages and Sparkle's appcast requests on to the
 * site unchanged while keeping anonymous counts, and answers the download address with a redirect to the release's
 * disk image, counting it by channel and architecture. It stores nothing else and logs nothing. */

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
/** Command-line and scripted clients excluded from site page visits (while still counted on download links). */
const SITE_CLI = /\b(?:curl|wget|httpie|undici|axios|okhttp|libwww-perl|yardlet-edge)\b|^node\b|^deno\b/i;
const UTM_SOURCE = /^[a-z0-9._-]{1,32}$/;
const REFERER_ALIASES: Record<string, string> = {
  "t.co": "x.com",
  "twitter.com": "x.com",
  "l.facebook.com": "facebook.com",
  "lm.facebook.com": "facebook.com",
  "l.instagram.com": "instagram.com",
  "lnkd.in": "linkedin.com",
  "l.linkedin.com": "linkedin.com",
  "out.reddit.com": "reddit.com",
  "old.reddit.com": "reddit.com",
  "youtu.be": "youtube.com",
  "search.naver.com": "naver.com",
};

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    const siteHost = new URL(env.FEED_ORIGIN ?? DEFAULT_FEED_ORIGIN).hostname;
    // Site routes only on the site's own host: anywhere else there is no origin to pass them to.
    if (url.hostname === siteHost) {
      const feed = FEEDS[url.pathname];
      if (feed) return passFeed(request, env, feed);
      return passSitePage(request, env, url, siteHost);
    }
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

/** Passes HTML page requests to GitHub Pages unchanged and records only an anonymous path and referrer host count. */
async function passSitePage(request: Request, env: EdgeEnv, url: URL, siteHost: string): Promise<Response> {
  const response = await fetch(request);
  const contentType = (response.headers.get("content-type") ?? "").toLowerCase();
  if (
    request.method === "GET" &&
    response.status >= 200 &&
    response.status < 300 &&
    contentType.includes("text/html") &&
    !isSiteBot(request.headers.get("user-agent"))
  ) {
    count(env.METRICS, "site.visit", [normalizeSitePath(url.pathname), visitSource(url, request.headers.get("referer"), siteHost)]);
  }
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

export function isSiteBot(agent: string | null): boolean {
  return isBot(agent) || SITE_CLI.test(agent!);
}

export function normalizeSitePath(pathname: string): string {
  if (pathname === "/index.html") return "/";
  if (pathname === "/blog/index.html") return "/blog/";
  return pathname || "/";
}

/** Coarse traffic source for a page visit: sanitized `utm_source`, normalized referring host, `internal`, or `direct`. */
export function visitSource(url: URL, referer: string | null, siteHost: string): string {
  const utm = (url.searchParams.get("utm_source") ?? "").trim().toLowerCase();
  if (utm && UTM_SOURCE.test(utm)) return `utm:${utm}`;
  if (!referer) return "direct";
  let parsed: URL;
  try {
    parsed = new URL(referer);
  } catch {
    return "direct";
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "direct";
  const stripped = parsed.hostname.toLowerCase().replace(/^(?:www\.|m\.|mobile\.)/, "");
  if (!stripped) return "direct";
  const own = siteHost.toLowerCase();
  if (stripped === own || stripped.endsWith(`.${own}`)) return "internal";
  if (REFERER_ALIASES[stripped]) return REFERER_ALIASES[stripped];
  if (/^google\.[a-z.]+$/.test(stripped)) return "google.com";
  return stripped;
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
