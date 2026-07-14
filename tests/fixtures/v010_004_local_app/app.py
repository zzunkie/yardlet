#!/usr/bin/env python3
import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MARKER = "yardlet-local-app"
BROWSER_SESSION_ID = "local-active-browser-session"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 200
        if self.path == "/health":
            body = json.dumps({"status": "ok", "marker": MARKER}).encode()
            content_type = "application/json"
        elif self.path == "/unhealthy":
            status = 503
            body = json.dumps({"status": "unhealthy", "marker": MARKER}).encode()
            content_type = "application/json"
        elif self.path == "/browser/session":
            body = json.dumps({"session_id": BROWSER_SESSION_ID, "marker": MARKER}).encode()
            content_type = "application/json"
        elif self.path == "/":
            body = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Yardlet local resource fixture</title>
  <style>
    body {{ margin: 0; background: #101820; color: #f2f2f2; font-family: sans-serif; }}
    main {{ width: 720px; margin: 96px auto; padding: 48px; border: 2px solid #f2aa4c; }}
    h1 {{ color: #f2aa4c; font-size: 42px; }}
    code {{ color: #8dd7cf; }}
  </style>
</head>
<body>
  <main id="{MARKER}">
    <h1>Local app is live</h1>
    <p>Rendered by a real localhost service for <code>{MARKER}</code>.</p>
  </main>
</body>
</html>
""".encode()
            content_type = "text/html; charset=utf-8"
        else:
            body = b"not found\n"
            content_type = "text/plain; charset=utf-8"
            self.send_response(404)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    print(f"starting local app on 127.0.0.1:{args.port}", file=sys.stderr, flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"listening on 127.0.0.1:{args.port}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
