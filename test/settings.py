#!/usr/bin/env python3
"""Real Lode with local Secrets, model and repository fixtures. See SPEC.md."""

import base64
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, urlopen


BINARY = Path(__file__).resolve().parents[1] / ".lake/build/bin/lode"
VAULT_PATH = "/v1/secret/data/lode/test-model"
SERVER_TOKEN = "fixture-server-token"
VAULT_TOKEN = "fixture-vault-token"


def request(base, path, method="GET", body=None, authenticated=True):
    headers = {"Authorization": f"Bearer {SERVER_TOKEN}"} if authenticated else {}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = Request(base + path, json.dumps(body).encode() if body is not None else None,
                  headers, method=method)
    def decode(response):
        data = response.read()
        if not data:
            return None
        if response.headers.get_content_type() == "application/json":
            return json.loads(data)
        return data.decode()
    try:
        with urlopen(req, timeout=5) as response:
            return response.status, decode(response)
    except HTTPError as error:
        return error.code, decode(error)


def until(read, done):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        value = read()
        if done(value):
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for fixture: {value}")


@contextmanager
def serve(settings, env, base):
    with subprocess.Popen([BINARY, "serve", "--settings", settings], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        def health():
            if process.poll() is not None:
                raise AssertionError(process.communicate())
            try:
                return request(base, "/_health", authenticated=False)[0]
            except URLError:
                return None

        try:
            until(health, lambda code: code == 200)
            yield
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)


def main():
    record = None
    vault_calls = []
    inference = []
    browser_challenge = None
    exchanges = []

    class Fixture(BaseHTTPRequestHandler):
        def reply(self, code, body=None):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if body is not None:
                self.wfile.write(json.dumps(body).encode())

        def do_GET(self):
            vault_calls.append(("GET", self.path, self.headers.get("Authorization")))
            if self.path == VAULT_PATH and self.headers.get("Authorization") == f"Bearer {VAULT_TOKEN}":
                self.reply(200, {"data": record})
            else:
                self.reply(401, {"error": "bad fixture credential or path"})

        def do_POST(self):
            nonlocal record
            payload = self.rfile.read(int(self.headers["Content-Length"]))
            auth = self.headers.get("Authorization")
            if self.path == "/token":
                fields = parse_qs(payload.decode())
                exchanges.append(fields)
                assert fields["client_id"] == ["lode-fixture"]
                assert fields["client_secret"] == ["fixture-client-secret"]
                assert auth is None
                if fields["grant_type"] == ["authorization_code"]:
                    assert fields["code"] == ["ab+012"]
                    digest = hashlib.sha256(fields["code_verifier"][0].encode()).digest()
                    assert base64.urlsafe_b64encode(digest).decode().rstrip("=") == browser_challenge
                    self.reply(200, {"access_token": "fixture-oauth-access", "refresh_token": "fixture-oauth-refresh",
                                     "expires_in": 2, "token_type": "Bearer"})
                else:
                    assert fields["grant_type"] == ["refresh_token"]
                    assert fields["refresh_token"] == ["fixture-oauth-refresh"]
                    self.reply(200, {"access_token": "fixture-oauth-rotated", "refresh_token": "fixture-oauth-next",
                                     "expires_in": 3600, "token_type": "Bearer"})
                return
            body = json.loads(payload)
            if self.path == VAULT_PATH:
                vault_calls.append(("POST", self.path, auth))
                if auth != f"Bearer {VAULT_TOKEN}":
                    self.reply(401, {"error": "bad fixture credential"})
                    return
                record = body
                self.reply(204)
            elif self.path == "/v1/chat/completions":
                inference.append((auth, body))
                if auth == "Bearer fixture-declined-key":
                    self.reply(401, {"error": "rejected fixture-declined-key"})
                    return
                self.reply(200, {"choices": [{"message": {"role": "assistant", "content": "Fixture reply."},
                                             "finish_reason": "stop"}]})
            else:
                self.reply(404, {"error": "missing fixture route"})

        def log_message(self, *_):
            pass

    with tempfile.TemporaryDirectory(prefix="lode-settings-") as scratch, \
            ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as fixture:
        worker = threading.Thread(target=fixture.serve_forever, daemon=True)
        worker.start()
        try:
            work = Path(scratch).resolve()
            state = work / "state"
            repo = work / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
            (repo / "Demo.lean").write_text("def answer : Nat := 42\n")
            (repo / "lean-toolchain").write_text((BINARY.parents[3] / "lean-toolchain").read_text())
            (repo / "lakefile.toml").write_text('name = "demo"\n[[lean_lib]]\nname = "Demo"\n')
            subprocess.run(["git", "-C", repo, "add", "."], check=True)
            subprocess.run(["git", "-C", repo, "-c", "user.name=fixture", "-c", "user.email=fixture@lode",
                            "-c", "commit.gpgsign=false", "commit", "-qm", "seed"], check=True)
            upstream = f"http://127.0.0.1:{fixture.server_port}"
            model_base = upstream + "/v1"
            toml = work / "settings.toml"
            toml.write_text(f'''workdir = "{state}"
allowLocal = true
toolchain = "leanprover/lean4:v4.36.0"
linenRev = "test-linen-pin"

[model]
provider = "scaleway"
name = "settings-fixture"
baseUrl = "{model_base}"

[secrets]
baseUrl = "{upstream}"
modelKeyPath = "lode/test-model"
''')
            settings = work / "settings.json"
            settings_content = {"port": 1, "workdir": str(state), "allowLocal": True,
                "model": {"provider": "baseten", "name": "http-fixture", "baseUrl": model_base},
                "secrets": {"baseUrl": upstream, "modelKeyPath": "lode/test-model"}}
            env = {key: value for key, value in os.environ.items() if not key.startswith("LODE_")}
            env.update(LODE_SETTINGS=str(toml), LODE_TOKEN=SERVER_TOKEN, LODE_SECRETS_TOKEN=VAULT_TOKEN)

            def cli(*args, key=None):
                child_env = env | ({"LODE_MODEL_API_KEY": key} if key is not None else {})
                return subprocess.run([BINARY, *args], env=child_env, cwd=work, input=b"Check the project.\n",
                                      capture_output=True, timeout=35)

            # S3: preview and missing noninteractive consent do not write.
            assert cli("secrets", "store-model-key", "--dry-run").returncode == 0
            assert cli("secrets", "store-model-key", key="fixture-api-key").returncode != 0
            assert not vault_calls
            result = cli("secrets", "store-model-key", "--yes", key="fixture-api-key")
            assert result.returncode == 0, result.stderr
            assert b"fixture-api-key" not in result.stdout + result.stderr
            assert record == {"modelBaseUrl": model_base, "apiKey": "fixture-api-key"}

            # S1/S2: TOML config reaches the real stdio model call and system prompt.
            result = cli("run", "--repo", repo)
            assert result.returncode == 0, result.stderr
            assert result.stdout == b"Fixture reply.\n"
            auth, body = inference[-1]
            assert auth == "Bearer fixture-api-key" and body["model"] == "settings-fixture"
            assert any("test-linen-pin" in message.get("content", "") and
                       "leanprover/lean4:v4.36.0" in message.get("content", "") for message in body["messages"])

            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            env.update(LODE_PORT=str(port), LODE_SETTINGS=str(work / "invalid-fallback.toml"))
            base = f"http://127.0.0.1:{port}"
            callback = "/v0/model-oauth/callback"
            settings_content["modelOAuth"] = {"authorizationUrl": upstream + "/authorize",
                "tokenUrl": upstream + "/token", "redirectUri": base + callback,
                "clientId": "lode-fixture", "scope": "inference offline_access"}
            settings.write_text(json.dumps(settings_content))
            env["LODE_OAUTH_CLIENT_SECRET"] = "fixture-client-secret"
            with serve(settings, env, base):
                # S1: --settings selects JSON over LODE_SETTINGS and the environment selects the port.
                spec = {"source": {"url": repo.as_uri(), "branch": "main"}}
                status, session = request(base, "/v0/sessions", "POST", spec)
                assert status == 201 and session["model"]["name"] == "http-fixture", (status, session)
                key_url = session["modelKeyUrl"]
                endpoint = "/v0/sessions/" + session["id"]
                captured = session["id"]
                until(lambda: request(base, endpoint)[1], lambda result: result["checkout"] == "ready")

                def send():
                    assert request(base, endpoint + "/messages", "POST", {"text": "Check again."})[0] == 202
                    return until(lambda: request(base, endpoint + "/messages")[1], lambda result: not result["running"])

                # S4: auth, targeted handoff, rotation, and clearing.
                assert request(base, key_url, "PUT", {"apiKey": "fixture-client-key"}, False)[0] == 401
                assert request(base, key_url, "PUT", {"apiKey": "bad\nkey"})[0] == 400
                assert request(base, key_url, "PUT", {"apiKey": "fixture-client-key"}) == (200, {"configured": True})
                assert send()["entries"][-1]["kind"] == "run_finished"
                assert inference[-1][0] == "Bearer fixture-client-key"
                assert request(base, key_url, "PUT", {"apiKey": "fixture-declined-key"})[0] == 200
                assert "fixture-declined-key" not in json.dumps(send())
                assert request(base, key_url, "PUT", {"apiKey": None}) == (200, {"configured": False})
                record["apiKey"] = "fixture-vault-rotation"
                assert send()["entries"][-1]["kind"] == "run_finished"
                assert inference[-1][0] == "Bearer fixture-vault-rotation"
                # S7: browser authorization binds state and verifier, then refreshes the session grant.
                start = session["modelOAuthUrl"]
                assert request(base, start, "POST", authenticated=False)[0] == 401
                status, first = request(base, start, "POST")
                assert status == 200
                stale = parse_qs(urlsplit(first["authorizationUrl"]).query)["state"][0]
                opener_dir = work / "browser-bin"
                opener_dir.mkdir()
                opener = opener_dir / ("open" if sys.platform == "darwin" else "xdg-open")
                opener.write_text('#!/bin/sh\n[ -z "$LODE_TOKEN" ] || exit 3\nprintf "%s\\n" "$1" > "$BROWSER_FIXTURE"\n')
                opener.chmod(0o700)
                browser_record = opener_dir / "url"
                opened = subprocess.run(
                    [BINARY, "oauth", base, session["id"], "--open"],
                    env=dict(env, PATH=f"{opener_dir}{os.pathsep}{env['PATH']}",
                             BROWSER_FIXTURE=str(browser_record)), capture_output=True, text=True, timeout=15,
                )
                assert opened.returncode == 0, opened.stderr
                assert browser_record.read_text() == opened.stdout
                authorize_url = urlsplit(opened.stdout.strip())
                authorize = parse_qs(authorize_url.query)
                assert authorize_url.path == "/authorize"
                assert authorize["scope"] == ["inference offline_access"]
                assert authorize["redirect_uri"] == [base + callback]
                assert authorize["code_challenge_method"] == ["S256"]
                browser_challenge = authorize["code_challenge"][0]
                assert request(base, callback + "?" + urlencode({"state": stale, "code": "ab+012"}),
                               authenticated=False)[0] == 400
                valid = callback + "?" + urlencode({"state": authorize["state"][0], "code": "ab+012"})
                assert request(base, valid + "&%73tate=" + authorize["state"][0], authenticated=False)[0] == 400
                with urlopen(base + valid, timeout=5) as browser:
                    assert browser.status == 200 and browser.headers["Cache-Control"] == "no-store"
                assert request(base, valid, authenticated=False)[0] == 400
                assert request(base, endpoint)[1]["modelOAuthConnected"]
                assert send()["entries"][-1]["kind"] == "run_finished"
                assert inference[-1][0] == "Bearer fixture-oauth-access"
                time.sleep(2)
                assert send()["entries"][-1]["kind"] == "run_finished"
                assert inference[-1][0] == "Bearer fixture-oauth-rotated"
                assert [form["grant_type"] for form in exchanges] == [["authorization_code"], ["refresh_token"]]
                # S3/S4: a mismatched base cannot disclose either key.
                wrong = spec | {"model": {"baseUrl": upstream + "/other"}}
                status, other = request(base, "/v0/sessions", "POST", wrong)
                assert status == 201 and other["modelKeyUrl"] is None
                assert other["modelOAuthUrl"] is None
                assert request(base, f"/v0/sessions/{other['id']}/model-key", "PUT", {"apiKey": "blocked"})[0] == 400
                assert request(base, key_url, "PUT", {"apiKey": "fixture-restart-key"})[0] == 200

                # S5: the normal server dispatches compiled tools only with explicit launch permission.
                extension = spec | {"message": "Find the Lean version.", "model": {"api": "scripted", "script": [
                    {"calls": [{"name": "extension", "arguments": {"name": "lean_version", "arguments": {}}}]},
                    {"text": "Done."}]}}
                for allowed in (False, True):
                    launch = extension | ({"tools": ["extension"]} if allowed else {})
                    status, created = request(base, "/v0/sessions", "POST", launch)
                    assert status == 201, created
                    path = f"/v0/sessions/{created['id']}/messages"
                    log = until(lambda: request(base, path)[1], lambda result: not result["running"])
                    tool = next(entry["results"][0] for entry in log["entries"] if entry["type"] == "tool_results")
                    assert tool["isError"] == (not allowed), tool
                    if allowed:
                        assert "Lean (version" in tool["content"], tool

            for file in (state / "sessions" / captured).glob("*.json*"):
                assert not any(key in file.read_text() for key in ("fixture-client-key", "fixture-declined-key",
                    "fixture-restart-key", "fixture-vault-rotation", "fixture-oauth-access",
                    "fixture-oauth-refresh", "fixture-oauth-rotated", "fixture-client-secret", VAULT_TOKEN))
            with serve(settings, env, base):
                assert not request(base, endpoint)[1]["modelOAuthConnected"]
                assert request(base, endpoint + "/messages", "POST", {"text": "After restart."})[0] == 202
                until(lambda: request(base, endpoint + "/messages")[1], lambda result: not result["running"])
                assert inference[-1][0] == "Bearer fixture-vault-rotation"
            assert all(path == VAULT_PATH and auth == f"Bearer {VAULT_TOKEN}" for _, path, auth in vault_calls)
            print("PASS: settings, Secrets, key handoff, browser OAuth with refresh, and compiled tool policy")
        finally:
            fixture.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
