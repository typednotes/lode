#!/usr/bin/env python3
"""Standard-library client regressions against a real local HTTP transport."""
import http.server
import json
from pathlib import Path
import sys
import threading
import time
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from Examples.client import ApiError, Client  # noqa: E402


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.responses = []
        test = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def handle_request(self):
                data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                test.requests.append((self.command, self.path, self.headers.get("Authorization"),
                                      json.loads(data) if data else None))
                status, body, headers = test.responses.pop(0)
                if isinstance(body, (dict, list)):
                    body = json.dumps(body, ensure_ascii=False)
                    headers = {"Content-Type": "application/json; charset=utf-8", **headers}
                encoded = body.encode("utf-8")
                self.send_response(status)
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            do_GET = do_POST = do_PUT = do_DELETE = handle_request

            def log_message(self, format, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = Client(f"http://127.0.0.1:{self.server.server_port}", "local-fixture")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def respond(self, body, status=200, **headers):
        self.responses.append((status, body, headers))

    def test_wire_json_text_empty_and_errors(self):
        spec = {"source": {"url": "file:///tmp/repo.git", "branch": "main"}, "tools": []}
        self.respond({"id": "session"}, 201)
        self.assertEqual(self.client.create(spec), {"id": "session"})
        self.assertEqual(self.requests[-1], ("POST", "/v0/sessions", "Bearer local-fixture", spec))
        self.respond("")
        self.assertEqual(self.client.request("GET", "/_health"), {"status": 200, "body": ""})
        self.respond("+ def café := 42\n")
        self.assertEqual(self.client.diff("session"), "+ def café := 42\n")
        self.respond({"error": "no such session"}, 404)
        with self.assertRaises(ApiError) as failure:
            self.client.status("missing")
        self.assertEqual(failure.exception.status, 404)
        self.assertEqual(failure.exception.body, {"error": "no such session"})
        self.respond({"error": "denied"}, 401)
        self.assertEqual(self.client.request("GET", "/v0/sessions")["status"], 401)

    def test_helpers_preserve_fields_and_http_methods(self):
        message = {"agent": "plan", "tools": [], "messageKey": "intent_1", "text": "Read λ."}
        self.respond({"queued": False, "session": {}}, 202)
        self.client.send("session", "Read λ.", agent="plan", tools=[], messageKey="intent_1")
        self.assertEqual(self.requests[-1][0:2], ("POST", "/v0/sessions/session/messages"))
        self.assertEqual(self.requests[-1][3], message)
        for method, suffix, invoke, body in [
            ("PUT", "/credentials", lambda: self.client.credentials("session", {"repo": None}), {"repo": None}),
            ("POST", "/answer", lambda: self.client.answer("session", "q1", "Round down"), {"id": "q1", "answer": "Round down"}),
            ("POST", "/abort", lambda: self.client.abort("session"), {}),
            ("DELETE", "", lambda: self.client.delete("session"), None),
        ]:
            self.respond({})
            invoke()
            self.assertEqual(self.requests[-1], (method, "/v0/sessions/session" + suffix, "Bearer local-fixture", body))
        self.respond({"sessions": [{"id": "session"}]})
        self.assertEqual(self.client.sessions(), [{"id": "session"}])
        self.respond({})
        self.client.status("not/a/path")
        self.assertEqual(self.requests[-1][1], "/v0/sessions/not%2Fa%2Fpath")

    def test_follow_background_cursor_and_terminal_error(self):
        # A background checkout has running:false before any task is running.
        self.respond({"entries": [], "next": 3, "running": False})
        self.respond({"state": "opening"})
        self.respond({"entries": [{"index": 3, "type": "event", "kind": "run_started"}], "next": 4, "running": True})
        self.respond({"entries": [{"index": 4, "type": "event", "kind": "error", "detail": "expired"}], "next": 5, "running": False})
        self.respond({"state": "idle", "error": "expired"})
        entries = list(self.client.follow("session", after=3, wait=0))
        self.assertEqual([entry["kind"] for entry in entries], ["run_started", "error"])
        queries = [urllib.parse.parse_qs(urllib.parse.urlsplit(r[1]).query) for r in self.requests if "/messages?" in r[1]]
        self.assertEqual([q["after"] for q in queries], [["3"], ["3"], ["4"]])
        self.assertEqual(len(self.responses), 0)

    def test_follow_stops_for_a_question_then_resumes(self):
        self.respond({"entries": [{"index": 0, "type": "event", "kind": "user_question"}], "next": 1, "running": False})
        self.respond({"state": "waiting", "question": {"id": "q1"}})
        self.assertEqual(len(list(self.client.follow("session", wait=0))), 1)
        self.respond({"state": "running"}, 202)
        self.client.answer("session", "q1", "yes")
        self.respond({"entries": [{"index": 1, "type": "event", "kind": "run_finished"}], "next": 2, "running": False})
        self.respond({"state": "idle"})
        self.assertEqual(list(self.client.follow("session", after=1, wait=0))[0]["kind"], "run_finished")

    def test_follow_drains_a_terminal_event_appended_between_snapshots(self):
        self.respond({"entries": [{"index": 0, "type": "assistant", "text": "Done"}], "next": 1, "running": False})
        self.respond({"state": "idle", "entries": 2})
        self.respond({"entries": [{"index": 1, "type": "event", "kind": "run_finished"}], "next": 2, "running": False})
        self.respond({"state": "idle", "entries": 2})
        entries = list(self.client.follow("session", wait=0))
        self.assertEqual([entry["index"] for entry in entries], [0, 1])
        self.assertEqual(entries[-1]["kind"], "run_finished")

    def test_deadline_does_not_abort_the_server(self):
        self.respond({"entries": [], "next": 0, "running": True})
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            list(self.client.follow("session", wait=0, timeout=0.1))
        self.assertLess(time.monotonic() - start, 1)
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][0], "GET")

    def test_redirect_is_not_followed_and_invalid_urls_are_refused(self):
        self.respond("redirect", 302, Location=self.client.base_url + "/_health")
        self.assertEqual(self.client.request("GET", "/redirect")["status"], 302)
        self.assertEqual(len(self.requests), 1)
        for base in ("file:///tmp/service", "https://key@example.com", "https://example.com?q=secret", "//example.com"):
            with self.assertRaises(ValueError):
                Client(base)
        for path in ("https://example.com", "//example.com", "/_health#fragment"):
            with self.assertRaises(ValueError):
                self.client.request("GET", path)
        for kwargs in ({"after": -1}, {"after": True}, {"wait": 61}, {"wait": 1.5}):
            with self.assertRaises(ValueError):
                self.client.messages("session", **kwargs)  # type: ignore[arg-type] -- deliberate invalid input


if __name__ == "__main__":
    unittest.main()
