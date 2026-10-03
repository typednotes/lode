#!/usr/bin/env python3
"""Native stdio integration: real local Git/Lake, scripted and direct model IO.

Run after lake build lode: python3 test/cli.py [.lake/build/bin/lode]
"""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".lake/build/bin/lode").resolve()


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args], text=True).strip()


def main():
    with tempfile.TemporaryDirectory(prefix="lode-cli-") as scratch:
        work = Path(scratch)
        seed = work / "seed"
        seed.mkdir()
        (seed / "lakefile.toml").write_text('name = "demo"\ndefaultTargets = ["Demo"]\n\n[[lean_lib]]\nname = "Demo"\n')
        (seed / "lean-toolchain").write_text((ROOT / "lean-toolchain").read_text())
        (seed / "Demo.lean").write_text("def Demo.answer : Nat := 42\n")
        git(seed, "init", "-q", "-b", "main")
        git(seed, "add", "-A")
        git(seed, "-c", "user.name=cli", "-c", "user.email=cli@lode", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "seed")
        remote = work / "remote.git"
        subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(remote)], check=True)
        # Lode's file:// grammar uses plain components; macOS TMPDIR qualifies.
        url = "file://" + str(remote)
        state = work / "state"
        env = {key: value for key, value in os.environ.items() if not key.startswith("LODE_")}
        env.update(LODE_WORKDIR=str(state), LODE_TOKEN="stdio-secret", LODE_MODEL_API_KEY="stdio-secret-key")

        def run(*args, task: str | bytes = "task\n", overrides=None):
            return subprocess.run([str(BINARY), *args], input=task.encode() if isinstance(task, str) else task,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env | (overrides or {}),
                                  cwd=work, timeout=60)

        def config(name, script, **fields):
            file = work / (name + ".json")
            file.write_text(json.dumps({"source": {"url": url, "branch": "main"},
                                        "model": {"api": "scripted", "script": script}, **fields}))
            return str(file)

        def calls(*items, text=None):
            return {"calls": [{"name": name, "arguments": arguments} for name, arguments in items],
                    **({"text": text} if text else {})}

        def session_id(result):
            match = re.search(rb"\[lode\] session ([0-9a-f]{32})", result.stderr)
            assert match is not None, result.stderr
            return match[1].decode()

        def entries(id):
            return [json.loads(line) for line in (state / "sessions" / id / "log.jsonl").read_text().splitlines()]

        def expect(result, code, answer=None):
            assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
            if answer is not None:
                assert result.stdout.decode() == answer, result.stdout

        for args in [("--help",), ("run", "--help")]:
            result = run(*args)
            expect(result, 0)
            assert b"stdin" in result.stdout and result.stderr == b""
        for args in [("unknown",), ("run",), ("run", "--repo"), ("run", "--repo", ".", "--agent", "bad")]:
            expect(run(*args), 2, "")
        print("ok - help and argument failures use the right streams/status")

        file = config("full", [
            calls(("write", {"path": "Demo.lean", "content": "def Demo.answer : Nat := 43\n"}),
                  ("check", {}), ("publish", {"message": "CLI smoke test"}), text="Working."),
            {"text": "Published 43."}, {"text": "Resumed."}])
        task = "Update the answer.\nThen publish. ✓\n"
        result = run("run", "--config", file, task=task)
        expect(result, 0, "Published 43.\n")
        assert b"Working." in result.stderr and b"Build succeeded" in result.stderr and b"Published " in result.stderr
        assert git(remote, "show", "main:Demo.lean") == "def Demo.answer : Nat := 43"
        assert git(remote, "log", "-1", "--format=%s", "main") == "CLI smoke test"
        id = session_id(result)
        assert next(entry for entry in entries(id) if entry["type"] == "user")["text"] == task
        expect(run("run", "--resume", id), 0, "Resumed.\n")
        assert len([entry for entry in entries(id) if entry.get("kind") == "run_finished"]) == 2
        print("ok - stdin UTF-8 task, real check/publication, clean stdout and persisted resume")

        before = len(list((state / "sessions").iterdir()))
        for task in [b"", b" \n", b"\xff", b"x" * (1024 * 1024 + 1)]:
            expect(run("run", "--config", file, task=task), 2, "")
        assert len(list((state / "sessions").iterdir())) == before
        expect(run("run", "--resume", "0" * 32), 1, "")
        print("ok - empty, oversized, invalid UTF-8 input and missing sessions")

        denied = config("denied", [calls(("write", {"path": "denied.txt", "content": "no"})), {"text": "Recovered."}], tools=[])
        result = run("run", "--config", denied)
        expect(result, 0, "Recovered.\n")
        assert b"[tool error] write" in result.stderr and b"denied by the session tool policy" in result.stderr, result.stderr
        assert not (state / "sessions" / session_id(result) / "checkout/denied.txt").exists()
        fuel = config("fuel", [calls(("read", {"path": "Demo.lean"})), {"text": "Recovered after fuel."}])
        result = run("run", "--config", fuel, overrides={"LODE_MAX_STEPS": "1"})
        expect(result, 1, "")
        assert b"out_of_fuel" in result.stderr
        expect(run("run", "--resume", session_id(result)), 0, "Recovered after fuel.\n")
        no_key = config("no-key", [], model={"api": "openai", "name": "fixture", "baseUrl": "https://example.com/v1"})
        result = run("run", "--config", no_key)
        expect(result, 1, "")
        assert b"no model credentials" in result.stderr
        print("ok - tool policy remains enforced, failures exit nonzero, exhausted sessions resume")

        bad = config("bad", [], source={"url": url, "branch": "missing"})
        expect(run("run", "--config", bad), 1, "")
        message = config("message", [], message="not from stdin")
        expect(run("run", "--config", message), 1, "")
        print("ok - missing branches and ambiguous config tasks fail")

        received = []

        class Model(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                received.append((self.path, self.headers.get("Authorization"), request))
                body = json.dumps({"choices": [{"message": {"role": "assistant", "content": "Direct reply."},
                                                 "finish_reason": "stop"}]}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *args):
                pass

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                direct = {"LODE_MODEL_API": "openai", "LODE_MODEL_NAME": "fixture",
                          "LODE_MODEL_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1"}
                result = run("run", "--repo", "remote.git", "--branch", "main", "--agent", "plan", overrides=direct)
                expect(result, 0, "Direct reply.\n")
                assert received[-1][0:2] == ("/v1/chat/completions", "Bearer stdio-secret-key")
                assert any(message.get("content") == "task\n" for message in received[-1][2]["messages"])
                assert b"stdio-secret-key" not in result.stdout + result.stderr
                home = work / "home"
                default_env = env.copy()
                del default_env["LODE_WORKDIR"]
                result = subprocess.run([str(BINARY), "run", "--repo", url], input=b"default state",
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=work,
                                        env=default_env | direct | {"HOME": str(home)}, timeout=60)
                expect(result, 0, "Direct reply.\n")
                assert (home / ".local/state/lode/sessions" / session_id(result) / "session.json").exists()
            finally:
                server.shutdown()
                thread.join()
        print("ok - relative repo shorthand, direct model transport and default user state")
        print("all CLI tests passed")


if __name__ == "__main__":
    main()
