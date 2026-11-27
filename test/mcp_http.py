#!/usr/bin/env python3
"""A loopback Streamable HTTP server for the compiled MCP adapter."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import threading


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = "2025-11-25"


def main():
    visits = []
    sessions = set()

    class Server(BaseHTTPRequestHandler):
        def check(self):
            assert self.path == "/mcp"
            assert self.headers["Authorization"] == "Bearer fixture-mcp-token"
            assert self.headers["Accept"] == "application/json, text/event-stream"

        def send(self, code, value=None, media="application/json", session=None):
            self.send_response(code)
            self.send_header("Content-Type", media)
            if session:
                self.send_header("Mcp-Session-Id", session)
            content = value.encode() if isinstance(value, str) else json.dumps(value).encode() if value else b""
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def do_POST(self):
            self.check()
            message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert message["jsonrpc"] == "2.0"
            method = message["method"]
            visits.append(method)
            if method == "initialize":
                assert message["params"]["protocolVersion"] == PROTOCOL
                assert self.headers.get("MCP-Protocol-Version") is None
                session = f"session-{len(visits)}"
                sessions.add(session)
                self.send(200, {"jsonrpc": "2.0", "id": message["id"], "result": {
                    "protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fixture", "version": "1"}}}, session=session)
                return
            assert self.headers["MCP-Protocol-Version"] == PROTOCOL
            assert self.headers["Mcp-Session-Id"] in sessions
            if method == "notifications/initialized":
                assert "id" not in message
                self.send(202)
                return
            if method == "tools/list":
                cursor = message["params"].get("cursor")
                if cursor is None:
                    result = {"tools": [{"name": "other", "inputSchema": {"type": "object"}}], "nextCursor": "page2"}
                else:
                    assert cursor == "page2"
                    result = {"tools": [{"name": "fixture_echo", "inputSchema": {"type": "object"}}]}
            else:
                assert method == "tools/call" and message["params"]["name"] == "fixture_echo"
                result = {"content": [], "structuredContent": {"echo": message["params"]["arguments"]["value"]}}
            notice = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {}})
            reply = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result})
            self.send(200, f"id: 1\r\ndata:\r\n\r\ndata: {notice}\r\n\r\ndata: {reply}\r\n\r\n", "text/event-stream")

        def do_DELETE(self):
            self.check()
            visits.append("delete")
            assert self.headers["MCP-Protocol-Version"] == PROTOCOL
            sessions.remove(self.headers["Mcp-Session-Id"])
            self.send(204)

        def log_message(self, *_):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Server) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            subprocess.run([ROOT / ".lake/build/bin/lode-mcp-smoke", f"http://127.0.0.1:{server.server_port}/mcp"],
                           cwd=ROOT, check=True, timeout=32)
        finally:
            server.shutdown()
            worker.join()
    assert visits == ["initialize", "notifications/initialized", "tools/list", "tools/list", "delete",
                      "initialize", "notifications/initialized", "tools/list", "tools/list", "tools/call", "delete"], visits
    assert not sessions
    print("PASS: HTTP bearer, session headers, paginated discovery, SSE notifications and cleanup")


if __name__ == "__main__":
    main()
