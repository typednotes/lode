#!/usr/bin/env python3
"""A stand-in for liaison's POST /v0/egress, for test/liaison.sh.

It checks the envelope lode sends (warrant, grant fields as strings, the
call), and answers the calls a session makes as the real hosts would, backed
by real git repositories:

  * GitHub/GitLab native repositories.read: immutable branch, tree and file
    views over GITHUB_REPO/GITLAB_REPO;
  * native repositories.write: a scoped commit plan with an expected-head
    compare-and-swap, implemented with real git plumbing;
  * Anthropic (https://api.anthropic.com/v1/messages): replies from the JSON
    list in MODEL_SCRIPT, in order; an entry with `_status` is answered with
    that status and `_headers` instead (a rate limit, say).

Every egress body is appended to LOG (one JSON object per line, with the
time it was received as `received`, in seconds). A warrant
whose expiresAt caveat is before the request's `now` is refused `expired`,
as liaison refuses it.

    mock_liaison.py PORT GITHUB_REPO GITLAB_REPO MODEL_SCRIPT LOG
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, GITHUB_REPO, GITLAB_REPO, MODEL_SCRIPT, LOG = sys.argv[1:6]
LOCK = threading.Lock()
MODEL_STEP = [0]
ENV = dict(os.environ, GIT_AUTHOR_NAME="host", GIT_AUTHOR_EMAIL="host@x",
           GIT_COMMITTER_NAME="host", GIT_COMMITTER_EMAIL="host@x",
           GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def git(repo, *args, input=None, env=None):
    r = subprocess.run(["git", "--git-dir", repo, *args], input=input, capture_output=True,
                       env=env or ENV)
    if r.returncode != 0:
        raise RuntimeError(f"git {args}: {r.stderr.decode()}")
    return r.stdout


def answer(status, body, headers=None):
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
    elif isinstance(body, str):
        body = body.encode()
    return {"status": status, "headers": headers or {}, "body": body.hex()}


def head(repo, branch):
    try:
        return git(repo, "rev-parse", f"refs/heads/{branch}").decode().strip()
    except RuntimeError:
        return None


def write_tree(repo, base_tree, edits):
    """edits: [(path, mode, sha or None)] applied on base_tree."""
    with tempfile.TemporaryDirectory() as d:
        env = dict(ENV, GIT_INDEX_FILE=os.path.join(d, "index"))
        if base_tree:
            git(repo, "read-tree", base_tree, env=env)
        lines = "".join(f"0 {'0' * 40}\t{path}\n" if sha is None else f"{mode} {sha}\t{path}\n"
                        for path, mode, sha in edits)
        git(repo, "update-index", "--index-info", input=lines.encode(), env=env)
        return git(repo, "write-tree", env=env).decode().strip()


def fast_forward(repo, branch, new, old):
    current = head(repo, branch)
    if current != old:
        return False
    git(repo, "update-ref", f"refs/heads/{branch}", new, old)
    return True


def repository(provider, call):
    """Fixture native views/publication; production authority is tested separately."""
    repo = GITHUB_REPO if provider == "github" else GITLAB_REPO
    resource = call["resource"]
    assert resource[:2] == ["acme", "demo"]
    payload = json.loads(call["payload"])
    if call["operation"] == "repositories.read":
        ref = payload["ref"]
        if payload.get("view") == "branch":
            assert resource == ["acme", "demo"] and ref == "main"
            sha = head(repo, ref)
            key = "sha" if provider == "github" else "id"
            return answer(200, {"commit": {key: sha}}) if sha else answer(404, {"message": "Branch not found"})
        assert len(ref) == 40 and all(c in "0123456789abcdef" for c in ref)
        if payload.get("view") == "tree":
            assert resource == ["acme", "demo"]
            entries = []
            for row in git(repo, "ls-tree", "-rz", ref).split(b"\0"):
                if not row:
                    continue
                info, path = row.decode().split("\t", 1)
                mode, kind, sha = info.split()
                entries.append({"path": path, "mode": mode, "type": kind, "sha": sha})
            return answer(200, {"tree": entries, "truncated": False})
        path = "/".join(resource[2:])
        assert path and all(p not in ("", ".", "..") for p in resource[2:])
        return answer(200, {"encoding": "base64", "content": base64.b64encode(git(repo, "show", f"{ref}:{path}")).decode()})
    assert call["operation"] == "repositories.write"
    assert resource == ["acme", "demo", "lean"]
    assert payload["view"] == "commit" and payload["branch"] == "main"
    old = payload["expectedHead"]
    if head(repo, "main") != old:
        return answer(409, {"message": "branch moved since expectedHead"})
    edits = []
    for change in payload["changes"]:
        parts = change["resource"]
        assert parts and all(p not in ("", ".", "..", ".git", ".lake") and "/" not in p for p in parts)
        path = "/".join(resource[2:] + parts)
        if change["delete"]:
            assert change["mode"] == "000000" and change["contents"] is None
            edits.append((path, None, None))
        else:
            assert change["mode"] in ("100644", "100755")
            sha = git(repo, "hash-object", "-w", "--stdin", input=change["contents"].encode()).decode().strip()
            edits.append((path, change["mode"], sha))
    tree = git(repo, "rev-parse", f"{old}^{{tree}}").decode().strip()
    new_tree = write_tree(repo, tree, edits)
    new = git(repo, "commit-tree", new_tree, "-p", old, "-m", payload["message"]).decode().strip()
    if not fast_forward(repo, "main", new, old):
        return answer(409, {"message": "branch moved during publication"})
    return answer(201, {"commit": new})


def anthropic(method, path, body):
    if method != "POST" or path != "/v1/messages":
        return answer(404, {"type": "error", "error": {"message": "not found"}})
    with open(MODEL_SCRIPT) as f:
        script = json.load(f)
    with LOCK:
        i = MODEL_STEP[0]
        MODEL_STEP[0] += 1
    reply = script[i] if i < len(script) else {"content": [{"type": "text", "text": "(end)"}]}
    if "_status" in reply:
        return answer(reply["_status"], {"type": "error", "error": {"type": "rate_limit_error"}},
                      reply.get("_headers"))
    reply = dict({"type": "message", "role": "assistant", "stop_reason": "end_turn",
                  "usage": {"input_tokens": 100, "output_tokens": 10}}, **reply)
    return answer(200, reply)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200 if self.path == "/_health" else 404, {"ok": True})

    def do_POST(self):
        if self.path != "/v0/egress":
            return self.reply(404, {"error": "not_found"})
        req = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with LOCK:
            with open(LOG, "a") as f:
                f.write(json.dumps(dict(req, received=time.time())) + "\n")
        for k in ["now", "cost", "provider", "action", "resource", "runId", "orgId"]:
            if not isinstance(req.get(k), str):
                return self.reply(400, {"error": "malformed_warrant", "field": k})
        expiry = [c for c in req["warrant"]["caveats"] if c["kind"] == "expiresAt"]
        if any(int(c["value"]) < int(req["now"]) for c in expiry):
            return self.reply(403, {"error": "expired"})
        call = req["call"]
        if call["account"].split("/")[-1] != req["resource"]:
            return self.reply(400, {"error": "malformed_warrant"})
        if call["kind"] != "connector":
            return self.reply(400, {"error": "malformed_warrant"})
        try:
            assert req["action"] == call["operation"]
            assert "url" not in call and "headers" not in call
            capabilities = [c for c in req["warrant"]["caveats"] if c["kind"] == "capability"]
            assert any(c["provider"] == req["provider"] and c["action"] == call["operation"] for c in capabilities)
            if req["provider"] in ("github", "gitlab"):
                out = repository(req["provider"], call)
            elif req["provider"] == "anthropic":
                assert call["operation"] == "inference.generate"
                assert call["resource"] == ["claude-test"]
                assert call["context"]["client"] == "typednotes-lode"
                out = anthropic("POST", "/v1/messages", json.loads(call["payload"]))
            else:
                return self.reply(403, {"error": "provider_denied"})
        except Exception as e:  # a bug in the mock or in lode's request
            out = answer(500, {"message": str(e)})
        self.reply(200, out)


ThreadingHTTPServer(("127.0.0.1", int(PORT)), Handler).serve_forever()
