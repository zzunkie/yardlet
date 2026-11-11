#!/usr/bin/env python3
"""A stand-in MCP server with MCP Apps views, for looking at connector views in a QA bundle without a real
service or a model turn (docs/CONNECTORS.md, "MCP Apps" and "QA (without a model turn)").

It serves Streamable HTTP on 127.0.0.1 without sign-in and lists:
  get_profile  read-only, view ui://qa/profile: a profile card that reports its own height at once
  get_me       read-only, view ui://github-mcp-server/get-me, only with --github-views: GitHub's own view,
               which measures itself in an animation frame (as GitHub's MCP server ships it)
  show_pull_request  read-only, view ui://github-mcp-server/pr-write, only with --github-views: GitHub's view for a
               new pull request, which shows a finished result rather than its form
  ui_lookup    only views may call it

usage: mcp-apps-server.py --output-dir DIR [--github-views DIR]
  DIR/port gets the port. --github-views names a folder with get-me.html and pr-write.html (the views as
  GitHub's MCP server release embeds them); nothing of them is kept in this repository.
"""
import argparse
import http.server
import json
import os
import sys

PROFILE_VIEW = """<!doctype html><html><head><meta charset="utf-8"><style>
:root { color-scheme: light dark; }
body { margin: 0; font: 13px var(--font-sans, -apple-system); color: var(--color-text-primary, #111); }
.card { display: flex; gap: 14px; align-items: center; padding: 16px; margin: 0; border-radius: 10px;
        background: var(--color-background-secondary, #f5f5f7); }
.avatar { width: 48px; height: 48px; border-radius: 50%; background: linear-gradient(135deg, #4c9aff, #7b61ff); }
.name { font-weight: 600; font-size: 15px; }
.meta { color: var(--color-text-secondary, #666); margin-top: 2px; }
.stats { display: flex; gap: 18px; margin-top: 8px; color: var(--color-text-secondary, #666); }
.stats b { color: var(--color-text-primary, #111); }
</style></head><body><div class="card"><div class="avatar"></div><div>
<div class="name" id="name">Loading</div><div class="meta" id="meta"></div>
<div class="stats"><span><b id="repos">0</b> repositories</span><span><b id="followers">0</b> followers</span></div>
</div></div><script>
let next = 0; const pending = {};
function request(method, params) {
  const id = ++next;
  parent.postMessage({ jsonrpc: '2.0', id, method, params }, '*');
  return new Promise((resolve) => { pending[id] = resolve; });
}
function notify(method, params) { parent.postMessage({ jsonrpc: '2.0', method, params }, '*'); }
function report() {
  notify('ui/notifications/size-changed',
         { width: document.body.scrollWidth, height: Math.ceil(document.body.getBoundingClientRect().height) });
}
window.addEventListener('message', (event) => {
  if (event.source !== parent) { return; }
  const message = event.data;
  if (message.id && pending[message.id]) { pending[message.id](message); delete pending[message.id]; return; }
  if (message.method === 'ui/notifications/host-context-changed' && message.params.theme) {
    document.documentElement.style.colorScheme = message.params.theme;
  }
  if (message.method !== 'ui/notifications/tool-result') { return; }
  const user = message.params.structuredContent || JSON.parse(message.params.content[0].text);
  document.getElementById('name').textContent = user.name;
  document.getElementById('meta').textContent = '@' + user.login + ' \\u00b7 ' + user.company;
  document.getElementById('repos').textContent = user.repos;
  document.getElementById('followers').textContent = user.followers;
  report();
});
(async () => {
  const answer = await request('ui/initialize', { appCapabilities: {}, protocolVersion: '2026-01-26' });
  const context = answer.result.hostContext;
  for (const [name, value] of Object.entries(context.styles.variables)) {
    document.documentElement.style.setProperty(name, value);
  }
  document.documentElement.style.colorScheme = context.theme;
  notify('ui/notifications/initialized', {});
  report();
})();
</script></body></html>"""

PROFILE = {"login": "octo", "name": "Mona Lisa Octocat", "company": "Example", "repos": 42, "followers": 1337}


def tool(name, title, read_only, ui, schema=None):
    return {"name": name, "title": title, "inputSchema": schema or {"type": "object"},
            "annotations": {"readOnlyHint": read_only}, "_meta": {"ui": ui}}


class Handler(http.server.BaseHTTPRequestHandler):
    github_views = None

    def log_message(self, format, *args):
        sys.stdout.write("%s %s\n" % (self.command, self.path))
        sys.stdout.flush()

    def reply(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/mcp":
            return self.reply(404, {"error": "not found"})
        message = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        method = message.get("method", "")
        if "id" not in message:
            return self.reply(202)
        params = message.get("params") or {}
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}, "resources": {}},
                      "serverInfo": {"name": "qa-apps", "version": "1"}}
        elif method == "tools/list":
            tools = [tool("get_profile", "Get profile", True, {"resourceUri": "ui://qa/profile"},
                          {"type": "object", "properties": {"login": {"type": "string"}}}),
                     tool("ui_lookup", "Look up", True, {"visibility": ["app"]})]
            if self.github_views:
                tools.append(tool("get_me", "Get my user profile", True,
                                  {"resourceUri": "ui://github-mcp-server/get-me", "visibility": ["model", "app"]}))
                tools.append(tool("show_pull_request", "Show a pull request", True,
                                  {"resourceUri": "ui://github-mcp-server/pr-write", "visibility": ["model", "app"]}))
            result = {"tools": tools}
        elif method == "tools/call":
            name = params.get("name")
            if name == "get_profile":
                result = {"content": [{"type": "text", "text": json.dumps(PROFILE)}], "structuredContent": PROFILE}
            else:
                result = {"content": [{"type": "text", "text": "[]"}]}
        elif method == "resources/read":
            uri = params.get("uri", "")
            if uri == "ui://qa/profile":
                html, ui = PROFILE_VIEW, {"prefersBorder": False, "csp": {}}
            elif uri == "ui://github-mcp-server/get-me" and self.github_views:
                with open(os.path.join(self.github_views, "get-me.html"), encoding="utf-8") as file:
                    html = file.read()
                ui = {"csp": {"resourceDomains": ["https://avatars.githubusercontent.com"]}, "prefersBorder": False}
            elif uri == "ui://github-mcp-server/pr-write" and self.github_views:
                with open(os.path.join(self.github_views, "pr-write.html"), encoding="utf-8") as file:
                    html = file.read()
                ui = {"csp": {}, "prefersBorder": True}
            else:
                return self.reply(200, {"jsonrpc": "2.0", "id": message["id"],
                                        "error": {"code": -32002, "message": "Resource not found"}})
            result = {"contents": [{"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": html,
                                    "_meta": {"ui": ui}}]}
        else:
            return self.reply(200, {"jsonrpc": "2.0", "id": message["id"],
                                    "error": {"code": -32601, "message": "no " + method}})
        self.reply(200, {"jsonrpc": "2.0", "id": message["id"], "result": result})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--github-views")
    arguments = parser.parse_args()
    Handler.github_views = arguments.github_views
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    os.makedirs(arguments.output_dir, exist_ok=True)
    with open(os.path.join(arguments.output_dir, "port"), "w") as file:
        file.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
