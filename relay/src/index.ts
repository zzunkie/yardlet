import { handleAccountRoute } from "./account-api";
import { handleFeedback } from "./feedback";
import { isRoom } from "./keys";
import { moveRoomPath, moveRoomsUntil, roomLocation, roomObjectName } from "./placement";
import { handlePushTargets } from "./push-targets";

export { Account } from "./account";
export { FeedbackSubmission } from "./feedback";
export { Room } from "./room";

const ROOM_PATH = /^\/v1\/rooms\/([^/]+)\/(host|connect|push-targets)$/;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/v1/health") {
      return request.method === "GET" ? new Response("ok") : new Response(null, { status: 405 });
    }
    if (pathname === "/v1/feedback") return handleFeedback(request, env);
    const match = ROOM_PATH.exec(pathname);
    if (!match) return (await handleAccountRoute(request, env)) ?? new Response("not found", { status: 404 });
    const [, room, role] = match;
    const methods = role === "push-targets" ? ["POST", "DELETE"] : ["GET"];
    if (!methods.includes(request.method)) return new Response(null, { status: 405 });
    if (!isRoom(room)) return new Response("malformed room", { status: 400 });
    if (role !== "push-targets" && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected a WebSocket upgrade", { status: 426 });
    }
    if (role !== "host" && Date.now() < moveRoomsUntil) {
      ctx.waitUntil(env.ROOM.get(env.ROOM.idFromName(room)).fetch(`https://relay${moveRoomPath}`, { method: "POST" }));
    }
    const location = roomLocation(request.cf?.country as string | undefined, request.cf?.continent as string | undefined);
    const stub = env.ROOM.get(env.ROOM.idFromName(roomObjectName(room)), location ? { locationHint: location } : undefined);
    return role === "push-targets" ? handlePushTargets(request, room, stub) : stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
