#!/usr/bin/env python3
"""A stand-in for liaison's POST /v0/egress, for test/liaison.sh.

It checks the envelope lode sends (warrant, grant fields as strings, the
call), and answers the calls a session makes as the real hosts would, backed
by real git repositories:

  * GitHub (https://api.github.com/repos/acme/demo/...): branches, tarball,
    git/commits, git/blobs, git/trees, git/refs — over the bare repository
    GITHUB_REPO, with git plumbing, so what lode publishes is a real commit;
  * GitLab (https://gitlab.com/api/v4/projects/acme%2Fdemo/...): branches,
    archive.tar.gz, commits with actions — over GITLAB_REPO;
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
import urllib.parse
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


def github(method, path, body):
    prefix = "/repos/acme/demo"
    if not path.startswith(prefix):
        return answer(404, {"message": "Not Found"})
    p = path[len(prefix):]
    repo = GITHUB_REPO
    if method == "GET" and p.startswith("/branches/"):
        sha = head(repo, urllib.parse.unquote(p[len("/branches/"):]))
        if not sha:
            return answer(404, {"message": "Branch not found"})
        return answer(200, {"name": "main", "commit": {"sha": sha}})
    if method == "GET" and p.startswith("/tarball/"):
        sha = p[len("/tarball/"):]
        data = git(repo, "archive", "--format=tar.gz", f"--prefix=acme-demo-{sha[:7]}/", sha)
        return answer(200, data)
    if method == "GET" and p.startswith("/git/commits/"):
        sha = p[len("/git/commits/"):]
        tree = git(repo, "rev-parse", f"{sha}^{{tree}}").decode().strip()
        return answer(200, {"sha": sha, "tree": {"sha": tree}})
    if method == "POST" and p == "/git/blobs":
        assert body["encoding"] == "base64"
        sha = git(repo, "hash-object", "-w", "--stdin", input=base64.b64decode(body["content"]))
        return answer(201, {"sha": sha.decode().strip()})
    if method == "POST" and p == "/git/trees":
        edits = [(e["path"], e["mode"], e["sha"]) for e in body["tree"]]
        return answer(201, {"sha": write_tree(repo, body["base_tree"], edits)})
    if method == "POST" and p == "/git/commits":
        args = ["commit-tree", body["tree"], "-m", body["message"]]
        for parent in body["parents"]:
            args += ["-p", parent]
        return answer(201, {"sha": git(repo, *args).decode().strip()})
    if method == "PATCH" and p.startswith("/git/refs/heads/"):
        branch = urllib.parse.unquote(p[len("/git/refs/heads/"):])
        assert body["force"] is False
        new = body["sha"]
        old = head(repo, branch)
        # A fast-forward: the new commit's parent is the current head.
        parent = git(repo, "rev-parse", f"{new}^").decode().strip()
        if parent != old or not fast_forward(repo, branch, new, old):
            return answer(422, {"message": "Update is not a fast forward"})
        return answer(200, {"object": {"sha": new}})
    return answer(404, {"message": f"no mock for {method} {p}"})


def gitlab(method, path, query, body):
    prefix = "/api/v4/projects/acme%2Fdemo"
    if not path.startswith(prefix):
        return answer(404, {"message": "404 Project Not Found"})
    p = path[len(prefix):]
    repo = GITLAB_REPO
    if method == "GET" and p.startswith("/repository/branches/"):
        sha = head(repo, urllib.parse.unquote(p[len("/repository/branches/"):]))
        if not sha:
            return answer(404, {"message": "404 Branch Not Found"})
        return answer(200, {"name": "main", "commit": {"id": sha}})
    if method == "GET" and p == "/repository/archive.tar.gz":
        sha = urllib.parse.parse_qs(query)["sha"][0]
        return answer(200, git(repo, "archive", "--format=tar.gz", f"--prefix=demo-{sha}/", sha))
    if method == "POST" and p == "/repository/commits":
        branch = body["branch"]
        old = head(repo, branch)
        tree = git(repo, "rev-parse", f"{old}^{{tree}}").decode().strip()
        edits = []
        for a in body["actions"]:
            if a["action"] == "delete":
                edits.append((a["file_path"], None, None))
            else:
                assert a["encoding"] == "base64"
                sha = git(repo, "hash-object", "-w", "--stdin",
                          input=base64.b64decode(a["content"])).decode().strip()
                mode = "100755" if a.get("execute_filemode") else "100644"
                edits.append((a["file_path"], mode, sha))
        new_tree = write_tree(repo, tree, edits)
        new = git(repo, "commit-tree", new_tree, "-p", old, "-m", body["commit_message"]).decode().strip()
        fast_forward(repo, branch, new, old)
        return answer(201, {"id": new})
    return answer(404, {"message": f"no mock for {method} {p}"})


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
        if call["kind"] != "provider" or call["account"].split("/")[-1] != req["resource"]:
            return self.reply(400, {"error": "malformed_warrant"})
        for h in call.get("headers", {}):
            if h.lower() in ("authorization", "x-api-key", "host", "content-length"):
                return self.reply(400, {"error": "header_denied"})
        url = urllib.parse.urlsplit(call["url"])
        body = json.loads(call["body"]) if call.get("body") else None
        try:
            if url.netloc == "api.github.com" and req["provider"] == "github":
                out = github(call["method"], url.path, body)
            elif url.netloc == "gitlab.com" and req["provider"] == "gitlab":
                out = gitlab(call["method"], url.path, url.query, body)
            elif url.netloc == "api.anthropic.com" and req["provider"] == "anthropic":
                out = anthropic(call["method"], url.path, body)
            else:
                return self.reply(403, {"error": "url_denied"})
        except Exception as e:  # a bug in the mock or in lode's request
            out = answer(500, {"message": str(e)})
        self.reply(200, out)


ThreadingHTTPServer(("127.0.0.1", int(PORT)), Handler).serve_forever()
