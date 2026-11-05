import { handleAccountRoute } from "./account-api";
import { isRoom } from "./keys";
import { roomLocation, roomObjectName } from "./placement";

export { Account } from "./account";
export { Room } from "./room";

const ROOM_PATH = /^\/v1\/rooms\/([^/]+)\/(host|connect)$/;

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/health") {
      return request.method === "GET" ? new Response("ok") : new Response(null, { status: 405 });
    }
    const match = ROOM_PATH.exec(pathname);
    if (!match) return (await handleAccountRoute(request, env)) ?? new Response("not found", { status: 404 });
    if (request.method !== "GET") return new Response(null, { status: 405 });
    const room = match[1];
    if (!isRoom(room)) return new Response("malformed room", { status: 400 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected a WebSocket upgrade", { status: 426 });
    }
    const location = roomLocation(request.cf?.country as string | undefined, request.cf?.continent as string | undefined);
    return env.ROOM.get(env.ROOM.idFromName(roomObjectName(room)), location ? { locationHint: location } : undefined)
      .fetch(request);
  },
} satisfies ExportedHandler<Env>;
