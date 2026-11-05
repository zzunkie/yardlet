// Where a room's Durable Object lives. Cloudflare creates a Durable Object near the location that first
// asks for it, and on a free-plan zone some networks reach the relay through a location far from them
// (Korean networks through Los Angeles or Hong Kong, for example). A room is created where its Mac
// is instead, by the country the request comes from; networks that already arrive nearby (North
// America, Europe) keep Cloudflare's own choice. A hint counts only when the object is first made.

/** The Durable Object name of a room. The prefix changed when rooms began to be placed by country, so
 * every room is made again where its Mac is; a room keeps nothing between connections. */
export function roomObjectName(room: string): string {
  return `v2:${room}`;
}

/** The internal request that tells a room's object from before `roomObjectName` to let its sockets go. A
 * code update keeps hibernated WebSockets, so a Mac connected through the change stays in the old object
 * while its phones now look for it in the new one; told this, the old object closes the Mac's socket with
 * 1012 and the Mac, connecting again, lands in the new object. The Worker never routes outside requests here. */
export const moveRoomPath = "/v1/internal/move-room";

/** Until when a phone's connection also tells the room's old object to let its Mac go. Every Mac has
 * connected again by then (a restart, sleep or a network change reconnects it). */
export const moveRoomsUntil = Date.UTC(2026, 11, 31);

const northeastAsia = new Set(["KR", "JP", "TW", "HK", "MO", "CN", "MN"]);
const southeastAsia = new Set(["SG", "MY", "ID", "TH", "VN", "PH", "KH", "LA", "MM", "BN", "TL"]);
const middleEast = new Set(["AE", "SA", "QA", "BH", "KW", "OM", "IL", "JO", "LB", "IQ", "IR", "YE", "SY", "TR"]);

/** The location hint for a room first asked for from `country` on `continent`, or undefined to let
 * Cloudflare place it near where the request arrived. */
export function roomLocation(country?: string, continent?: string): DurableObjectLocationHint | undefined {
  if (!country) return undefined;
  if (northeastAsia.has(country)) return "apac-ne";
  if (southeastAsia.has(country)) return "apac-se";
  if (middleEast.has(country)) return "me";
  switch (continent) {
    case "AS":
      return "apac";
    case "OC":
      return "oc";
    case "SA":
      return "sam";
    case "AF":
      return "afr";
    default:
      return undefined;
  }
}
