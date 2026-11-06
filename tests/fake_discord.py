#!/usr/bin/env python3
"""A stand-in for Discord's webhook and bot API, for the tests: fake_discord.py <dir>.

Records every call as "METHOD path" in <dir>/calls and each body in <dir>/bodies, writes
its port to <dir>/port, and answers the way Discord does: a card gets id card-1 (or
FAKE_DISCORD_CARD_ID), each alert alert-N, peers are served from <dir>/peer/, and the
files <dir>/patch-404 and <dir>/delete-fails make an edit or a delete fail.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(sys.argv[1])
CARD_ID = os.environ.get("FAKE_DISCORD_CARD_ID", "card-1")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, text):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(text.encode())))
        self.end_headers()
        self.wfile.write(text.encode())

    def handle_any(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        with (ROOT / "calls").open("a", encoding="utf-8") as f:
            f.write(f"{self.command} {self.path}\n")
        with (ROOT / "bodies").open("a", encoding="utf-8") as f:
            f.write(body + "\n")
        path = self.path
        if self.command == "GET":
            if path.startswith("/peer/"):
                peer = ROOT / "peer" / path[6:]
                return self.answer(200, peer.read_text(encoding="utf-8")) if peer.is_file() else self.answer(404, "")
            if path.endswith("/channels/22"):
                return self.answer(200, '{"id":"22","guild_id":"11","topic":"","permission_overwrites":[]}')
            if path.endswith("/guilds/11/roles"):
                return self.answer(200, "[]")
            return self.answer(200, "{}")
        if self.command == "DELETE":
            return self.answer(500 if (ROOT / "delete-fails").exists() else 204, "")
        if self.command == "PATCH" and (ROOT / "patch-404").exists():
            return self.answer(404, "{}")
        if self.command == "POST" and path.endswith("/guilds/11/roles"):
            return self.answer(200, '{"id":"33","name":"Server alerts"}')
        if '"content"' in body and '"components"' not in body:
            n = int((ROOT / "alerts").read_text() or 0) + 1 if (ROOT / "alerts").exists() else 1
            (ROOT / "alerts").write_text(str(n))
            return self.answer(200, json.dumps({"id": f"alert-{n}"}))
        return self.answer(200, json.dumps({"id": CARD_ID}))

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_any


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    server = HTTPServer(("127.0.0.1", 0), Handler)
    (ROOT / "port").write_text(str(server.server_port))
    server.serve_forever()
