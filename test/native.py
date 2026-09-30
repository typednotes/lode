#!/usr/bin/env python3
"""Native writer integration: real Lode, an in-process fake credential broker.

No network credentials, billed requests or remote repository writes. Run after
building against the local SDK workspace: python3 test/native.py PATH_TO_LODE.
The fake authenticates fixture-shaped warrants only; it does not replace the
broker's own authority/adapter tests.
"""
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


TMP = Path("/var/folders/83/bq8tqpf57rv3ff7ftlnmh6k80000gp/T/opencode")
CASES = [
    ("anthropic", "claude-test", "anthropic"),
    ("groq", "chat-test", "openai"),
    ("openai", "gpt-6-test", "responses"),
    ("gemini", "gemini-test", "gemini"),
    ("radius", "radius-test", "pi"),
    ("opencode-go", "minimax-m3", "anthropic"),
    ("opencode-go", "qwen3.8-max", "anthropic"),
    ("opencode", "qwen3.8-max", "openai"),
    ("opencode-go", "muse-spark-1.3-contributor", "responses"),
    ("github-copilot", "gpt-5-mini", "openai"),
    ("github-copilot", "gpt-6", "responses"),
    ("github-copilot", "claude-test", "anthropic"),
]


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def credentials(provider, ident="initial", org="org", account="user/conn", action="inference.generate"):
    return {"account": account, "cost": 3, "warrant": {
        "id": ident, "orgId": org, "tag": "00", "caveats": [
            {"kind": "expiresAt", "value": "9999999999"},
            {"kind": "capability", "provider": provider, "action": action},
            {"kind": "resource", "value": "conn"},
            {"kind": "budget", "value": "1000"},
            {"kind": "runId", "value": "changing-run-" + ident}]}}


CALLS = [
    ("todo", {"todos": [{"content": "checked", "status": "completed"}]}),
    ("read", {"path": "fixture.txt"}),
    ("ls", {}),
    ("grep", {"pattern": "fixture"}),
    ("write", {"path": "DENIED", "content": "must not be written"}),
    ("edit", {"path": "fixture.txt", "old": "fixture", "new": "changed"}),
    ("bash", {"command": "touch DENIED_BASH"}),
    ("check", {}),
    ("publish", {"message": "must not publish"}),
    ("lun_build", {}),
    ("lun_call", {"kind": "function", "name": "test"}),
    ("unknown", {}),
]


def response(api, stage, model):
    """The second answer hits the output limit; the third completes the run."""
    calls = CALLS if stage == 0 else []
    content = "working" if stage == 0 else "partial" if stage == 1 else "done"
    ids = ["c" + str(i) for i in range(len(calls))]
    if api == "anthropic":
        blocks = [{"type": "thinking", "thinking": "private reasoning", "signature": "signed"},
                  {"type": "text", "text": content}]
        blocks += [{"type": "tool_use", "id": cid, "name": name, "input": args}
                   for cid, (name, args) in zip(ids, calls)]
        return {"content": blocks, "stop_reason": "tool_use" if calls else "max_tokens" if stage == 1 else "end_turn",
                "usage": {"input_tokens": 6, "output_tokens": 2, "cache_read_input_tokens": 4}}
    if api == "openai":
        message = {"content": content, "reasoning_content": "reasoning-replay"}
        if calls:
            message["tool_calls"] = [{"id": cid, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
                                     for cid, (name, args) in zip(ids, calls)]
        return {"choices": [{"message": message, "finish_reason": "tool_calls" if calls else "length" if stage == 1 else "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 2, "prompt_tokens_details": {"cached_tokens": 4}}}
    if api == "responses":
        output = [{"type": "reasoning", "id": "reasoning-" + str(stage), "summary": [], "encrypted_content": "encrypted-replay"},
                  {"type": "message", "role": "assistant", "id": "msg-" + str(stage), "status": "completed",
                   "content": [{"type": "output_text", "text": content, "annotations": []}]}]
        output += [{"type": "function_call", "id": "fc-" + cid, "call_id": cid, "name": name,
                    "arguments": json.dumps(args), "status": "completed"} for cid, (name, args) in zip(ids, calls)]
        return {"status": "incomplete" if stage == 1 else "completed", "output": output,
                "incomplete_details": {"reason": "max_output_tokens"} if stage == 1 else None,
                "usage": {"input_tokens": 10, "output_tokens": 2, "input_tokens_details": {"cached_tokens": 4}}}
    if api == "gemini":
        parts = [{"text": content, "thoughtSignature": "text-signature"}]
        parts += [{"functionCall": {"id": cid, "name": name, "args": args}, "thoughtSignature": "tool-signature-" + cid}
                  for cid, (name, args) in zip(ids, calls)]
        return {"candidates": [{"content": {"role": "model", "parts": parts}, "finishReason": "MAX_TOKENS" if stage == 1 else "STOP"}],
                "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 2, "cachedContentTokenCount": 4}}
    events = [{"type": "start"}, {"type": "thinking_start", "contentIndex": 0},
              {"type": "thinking_end", "contentIndex": 0, "content": "thought", "contentSignature": "pi-signature"},
              {"type": "text_start", "contentIndex": 1}, {"type": "text_delta", "contentIndex": 1, "delta": content},
              {"type": "text_end", "contentIndex": 1, "content": content, "contentSignature": "pi-text-signature"}]
    for i, (cid, (name, args)) in enumerate(zip(ids, calls), 2):
        events += [{"type": "toolcall_start", "contentIndex": i, "id": cid, "toolName": name},
                   {"type": "toolcall_end", "contentIndex": i,
                    "toolCall": {"type": "toolCall", "id": cid, "name": name, "arguments": args, "thoughtSignature": "pi-tool-signature"}}]
    events += [{"type": "done", "reason": "toolUse" if calls else "length" if stage == 1 else "stop",
                "usage": {"input": 6, "output": 2, "cacheRead": 4, "cacheWrite": 0}}]
    return "".join("data: " + json.dumps(event) + "\r\n\r\n" for event in events)


class Broker:
    def __init__(self):
        self.requests = []
        self.steps = {}
        self.errors = []
        self.block = None
        self.entered = threading.Event()
        self.release = threading.Event()
        self.cases = { (p, m): api for p, m, api in CASES }
        self.cases[("groq", "refresh-test")] = "openai"

    def handle(self, req):
        call = req["call"]
        assert call["kind"] == "connector" and call["operation"] == req["action"] == "inference.generate"
        assert set(call) == {"kind", "account", "operation", "resource", "payload", "context"}
        assert call["account"] == "user/conn" and req["resource"] == "conn"
        assert req["cost"] == "3"
        for name in ("cost", "now", "runId", "orgId"):
            assert isinstance(req[name], str)
        key = (req["provider"], call["resource"][0])
        assert len(call["resource"]) == 1
        api = self.cases[key]
        body = json.loads(call["payload"])
        ctx = call["context"]
        assert set(ctx) == {"sessionId", "initiator", "client"}
        assert ctx["client"] == "typednotes-lode" and ctx["initiator"] in ("user", "agent")
        session = ctx["sessionId"]
        self.requests.append(copy.deepcopy(req))
        if api == "anthropic":
            system = body["system"]
            system = system[0]["text"] if isinstance(system, list) else system
            names = [tool["name"] for tool in body.get("tools", [])]
        elif api == "openai":
            system = body["messages"][0]["content"]
            names = [tool["function"]["name"] for tool in body.get("tools", [])]
        elif api == "responses":
            system = body["instructions"]
            names = [tool["name"] for tool in body.get("tools", [])]
            assert body["store"] is False and body["include"] == ["reasoning.encrypted_content"]
        elif api == "gemini":
            system = body["systemInstruction"]["parts"][0]["text"]
            names = [tool["name"] for group in body.get("tools", []) for tool in group["functionDeclarations"]]
        else:
            system = body["context"]["messages"][0]["content"]
            names = [tool["name"] for tool in body["context"]["messages"][0]["toolsAdded"]]
            assert body["options"]["sessionId"] == session
        summary = system.startswith("You summarize a coding session")
        if summary:
            assert not names and ctx["initiator"] == "agent"
            return 200, response(api, 2, key[1]), {}
        stage = self.steps.get(session, 0)
        assert names == ([] if key[1] == "refresh-test" and stage > 0 else ["todo"])
        if stage == 0 and key[1] == "chat-test" and not any(r.get("_retried") for r in self.requests if r["call"]["context"]["sessionId"] == session):
            self.requests[-1]["_retried"] = True
            return 429, {"error": {"message": "fixture rate limit"}}, {"retry-after": "0"}
        if stage == 0 and key == self.block:
            self.entered.set()
            assert self.release.wait(20)
        if stage == 1:
            encoded = json.dumps(body)
            assert "denied" in encoded.lower() or "not available" in encoded.lower()
            assert "removed from replay" in encoded
            assert '"c1"' not in encoded  # the denied read function is not replay authority
        self.steps[session] = stage + 1
        return 200, response(api, stage, key[1]), {}


def main(binary):
    broker = Broker()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v0/egress"
                req = json.loads(self.rfile.read(int(self.headers["content-length"])))
                code, body, headers = broker.handle(req)
                raw = body.encode() if isinstance(body, str) else json.dumps(body).encode()
                data = json.dumps({"status": code, "headers": headers, "body": raw.hex()}).encode()
            except Exception as exc:
                broker.errors.append(repr(exc))
                data = json.dumps({"status": 400, "headers": {}, "body": str(exc).encode().hex()}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="lode-native-", dir=TMP) as directory:
            work = Path(directory)
            seed = work / "seed"
            seed.mkdir()
            env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                       GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                       GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")

            def git(*args, data=None):
                return subprocess.check_output(["git", "-C", str(seed), *args], input=data, env=env).decode().strip()

            git("init", "-q", "-b", "main")
            blob = git("hash-object", "-w", "--stdin", data=b"fixture\n")
            tree = git("mktree", data=f"100644 blob {blob}\tfixture.txt\n".encode())
            commit = git("commit-tree", tree, data=b"test fixture\n")
            git("update-ref", "refs/heads/main", commit)
            http_port = port()
            base = "http://127.0.0.1:" + str(http_port)
            log = (work / "lode.log").open("w+")
            runenv = {k: v for k, v in os.environ.items() if not k.startswith("LODE_")}
            runenv.update(LODE_WORKDIR=str(work / "state"), LODE_ALLOW_LOCAL="1", LODE_PORT=str(http_port),
                          LODE_TOKEN="fixture", LODE_LIAISON_URL=f"http://127.0.0.1:{server.server_port}")

            def start():
                return subprocess.Popen([str(Path(binary).resolve())], env=runenv, stdout=log, stderr=log)

            def api(method, path, body=None, expected=200):
                data = None if body is None else json.dumps(body).encode()
                request = urllib.request.Request(base + path, data=data, method=method,
                    headers={"authorization": "Bearer fixture", "content-type": "application/json"})
                try:
                    with urllib.request.urlopen(request, timeout=30) as reply:
                        raw = reply.read()
                        status, payload = reply.status, json.loads(raw) if raw else {}
                except urllib.error.HTTPError as exc:
                    status, payload = exc.code, json.load(exc)
                assert status == expected, (method, path, status, payload)
                return payload

            def ready(process):
                for _ in range(100):
                    try:
                        api("GET", "/_health")
                        return
                    except (OSError, AssertionError):
                        if process.poll() is not None:
                            log.seek(0)
                            raise AssertionError(log.read())
                        time.sleep(.1)
                raise AssertionError("Lode did not start")

            def create(provider, model_id, protocol, **extra):
                body = {"source": {"url": seed.as_uri(), "branch": "main"}, "tools": ["todo"],
                        "model": {"api": protocol, "name": model_id, "baseUrl": "https://fixture.invalid/v1",
                                  "maxTokens": 256, "credentials": credentials(provider)}}
                body.update(extra)
                return api("POST", "/v0/sessions", body, 201)["id"]

            def idle(ident):
                for _ in range(100):
                    result = api("GET", f"/v0/sessions/{ident}/messages?wait=1")
                    if not result["running"]:
                        assert result["entries"][-1].get("kind") == "run_finished", result
                        return result
                    time.sleep(.05)
                raise AssertionError("session did not finish")

            process = start()
            try:
                ready(process)
                for provider, model, protocol in CASES:
                    ident = create(provider, model, protocol)
                    api("POST", f"/v0/sessions/{ident}/messages", {"text": "Implement the fixture"}, 202)
                    entries = idle(ident)["entries"]
                    results = next(e["results"] for e in entries if e["type"] == "tool_results")
                    assert [r["isError"] for r in results] == [False] + [True] * (len(CALLS) - 1), results
                    checkout = work / "state" / "sessions" / ident / "checkout"
                    assert not (checkout / "DENIED").exists() and not (checkout / "DENIED_BASH").exists()
                    assert (checkout / "fixture.txt").read_text() == "fixture\n"
                    status = api("GET", f"/v0/sessions/{ident}")
                    assert status["tools"] == ["todo"] and status["todos"][0]["content"] == "checked"
                    assert status["usage"] == {"input": 18, "output": 6, "cacheRead": 12, "cacheWrite": 0}, status
                    sent = [r for r in broker.requests if r["call"]["context"]["sessionId"] == ident]
                    assert len(sent) == (4 if model == "chat-test" else 3)
                    assert all(r["call"]["context"]["sessionId"] == ident for r in sent)
                    assert any("cut off" in e.get("text", "") for e in entries if e["type"] == "user")
                    print(f"ok - {provider}/{model}: native replay, tool denial, usage, output continuation")

                # Compaction also uses the conversation ID and agent initiator.
                ident = create("openai", "gpt-6-test", "responses", model={
                    "api": "responses", "name": "gpt-6-test", "baseUrl": "https://fixture.invalid/v1",
                    "maxTokens": 256, "contextWindow": 8000, "credentials": credentials("openai")})
                api("POST", f"/v0/sessions/{ident}/messages", {"text": "Compact this conversation"}, 202)
                entries = idle(ident)["entries"]
                assert any(e["type"] == "compaction" for e in entries)
                print("ok - compaction: native transport and stable conversation metadata")

                # While a model call is outstanding, refresh/narrow; the returned
                # call must be denied and the next model call uses the fresh warrant.
                broker.block = ("groq", "refresh-test")
                ident = create("groq", "refresh-test", "openai")
                api("POST", f"/v0/sessions/{ident}/messages", {"text": "Wait for refresh"}, 202)
                assert broker.entered.wait(10)
                path = f"/v0/sessions/{ident}"
                api("POST", path + "/messages", {"text": "Narrow now", "tools": [],
                    "credentials": {"model": credentials("groq", "fresh")}}, 202)
                broker.release.set()
                entries = idle(ident)["entries"]
                results = next(e["results"] for e in entries if e["type"] == "tool_results")
                assert all(r["isError"] for r in results)
                sent = [r for r in broker.requests if r["call"]["context"]["sessionId"] == ident]
                assert sent[0]["warrant"]["id"] == "initial" and all(r["warrant"]["id"] == "fresh" for r in sent[1:])
                assert all(r["call"]["context"]["sessionId"] == ident for r in sent)
                for invalid in (["todo"], ["unknown"], None):
                    api("POST", path + "/messages", {"text": "Widen", "tools": invalid}, 400)
                for bad in (credentials("groq", org="other"), credentials("groq", account="other/conn"),
                            credentials("openai"), credentials("groq", action="read")):
                    api("PUT", path + "/credentials", {"model": bad}, 400)
                api("PUT", path + "/credentials", {"model": credentials("groq", "new"), "tools": ["bash"]}, 400)
                api("POST", path + "/messages", {"text": "Bad agent", "agent": "invalid",
                    "credentials": {"model": credentials("groq", "unapplied")}}, 400)
                api("POST", path + "/messages", {"text": "Verify unchanged credentials"}, 202)
                idle(ident)
                assert broker.requests[-1]["warrant"]["id"] == "fresh"
                assert api("GET", path)["tools"] == []
                print("ok - in-flight narrowing and credential refresh cannot widen tool/identity authority")

                # Restart preserves both the launch ceiling and the narrower
                # current policy; attaching credentials cannot revive removed tools.
                process.terminate()
                process.wait(timeout=10)
                process = start()
                ready(process)
                assert api("GET", path)["tools"] == []
                api("PUT", path + "/credentials", {"model": credentials("groq", "restored")})
                api("POST", path + "/messages", {"text": "Restore todo", "tools": ["todo"]}, 400)
                assert api("GET", path)["tools"] == []
                assert not broker.errors, broker.errors
                print("ok - restart preserves the attenuated policy")
            finally:
                broker.release.set()
                process.terminate()
                process.wait(timeout=10)
                log.close()
    finally:
        server.shutdown()
        server.server_close()
    print("all native integration checks passed")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".lake/build/bin/lode")
