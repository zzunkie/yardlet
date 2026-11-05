// Hands every request, WebSocket upgrades included, to the relay Worker (wrangler.toml's RELAY binding).
export default {
  fetch(request, env) {
    return env.RELAY.fetch(request);
  },
};
