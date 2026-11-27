#!/usr/bin/env python3
"""Compare a tool turn and a persisted resume against Pi with one local model."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Thread


ROOT = Path(__file__).resolve().parents[1]
TASK = "Write the Lean fixture."
RESUME = "Resume the fixture session."
BODY = "def add (a b : Nat) : Nat := a + b\n"


class Model(BaseHTTPRequestHandler):
    requests = None

    def log_message(self, *_):
        pass

    def do_POST(self):
        assert self.path == "/v1/chat/completions", self.path
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        last = messages[-1]
        stream = request.get("stream", False)
        self.requests.append((stream, last["role"], json.dumps(messages)))
        call = {"id": "call_write", "type": "function", "function": {
            "name": "write", "arguments": json.dumps({"path": "Addition.lean", "content": BODY}),
        }}
        if last["role"] == "tool":
            message, reason = {"content": "Wrote the fixture."}, "stop"
        elif RESUME in json.dumps(last["content"]):
            message, reason = {"content": "Resumed the fixture."}, "stop"
        else:
            assert any(tool["function"]["name"] == "write" for tool in request["tools"])
            message, reason = {"tool_calls": [call]}, "tool_calls"

        envelope = {"id": "fixture", "created": 1, "model": request["model"]}
        if stream:
            if "tool_calls" in message:
                call["index"] = 0
            chunks = [
                dict(envelope, object="chat.completion.chunk", choices=[
                    {"index": 0, "delta": dict(message, role="assistant"), "finish_reason": None},
                ]),
                dict(envelope, object="chat.completion.chunk", choices=[
                    {"index": 0, "delta": {}, "finish_reason": reason},
                ]),
            ]
            body = "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks) + "data: [DONE]\n\n"
            media = "text/event-stream"
        else:
            body = json.dumps(dict(envelope, choices=[
                {"index": 0, "message": dict(message, role="assistant"), "finish_reason": reason},
            ]))
            media = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(body.encode())))
        self.end_headers()
        self.wfile.write(body.encode())


def main():
    pi = shutil.which("pi")
    if pi is None:
        raise SystemExit("Install Pi to run this opt-in comparison")
    with tempfile.TemporaryDirectory(prefix="lode-pi-") as tmp, \
            ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        work = Path(tmp).resolve()
        Model.requests = []
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}/v1"
            env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
            env.update(LODE_WORKDIR=str(work / "state"), LODE_MODEL_API="openai", LODE_MODEL_NAME="fixture",
                       LODE_MODEL_BASE_URL=base, LODE_MODEL_API_KEY="local-fixture",
                       GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
            pi_config = work / "pi"
            pi_config.mkdir()
            (pi_config / "models.json").write_text(json.dumps({"providers": {
                "fixture": {"baseUrl": base, "api": "openai-completions", "apiKey": "local-fixture",
                            "models": [{"id": "fixture", "maxTokens": 2048, "contextWindow": 65536}]},
            }}))
            env.update(PI_CODING_AGENT_DIR=str(pi_config), PI_OFFLINE="1", PI_TELEMETRY="0")

            def run(*args, cwd=work, task=None):
                result = subprocess.run(args, cwd=cwd, env=env, input=task,
                                        capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, (args, result.stdout, result.stderr)
                return result.stdout

            repo = work / "repo"
            repo.mkdir()
            run("git", "init", "-q", "-b", "main", cwd=repo)
            run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@lode",
                "commit", "-qm", "Fixture", "--allow-empty", cwd=repo)
            lode = ROOT / ".lake/build/bin/lode"
            assert run(lode, "run", "--repo", repo, task=TASK) == "Wrote the fixture.\n"
            session = next((work / "state/sessions").iterdir())
            assert (session / "checkout/Addition.lean").read_text() == BODY
            assert run(lode, "run", "--resume", session.name, task=RESUME) == "Resumed the fixture.\n"
            lode_requests = Model.requests[:]
            Model.requests.clear()

            flags = [pi, "-p", "--offline", "--no-approve", "--no-extensions", "--no-mcp",
                     "--no-skills", "--no-context-files", "--tools", "write", "--model", "fixture/fixture",
                     "--session-dir", work / "pi-sessions"]
            assert run(*flags, "--", TASK, cwd=repo).strip() == "Wrote the fixture."
            assert (repo / "Addition.lean").read_text() == BODY
            resumed = run(*flags, "--continue", "--", RESUME, cwd=repo).strip()
            assert resumed == "Resumed the fixture.", resumed
            for requests in (lode_requests, Model.requests):
                roles = [role for _, role, _ in requests]
                assert roles == ["user", "tool", "user"], roles
                assert "call_write" in requests[2][2] and TASK in requests[2][2]
            print("PASS: Lode and Pi write the same Lean file, deliver the tool result, and resume the tool history")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
