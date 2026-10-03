#!/usr/bin/env python3
"""Real Lean 4.34 LSP and adversarial-pipe tests through Tools.execute.

Run after `lake build +Lode.Tools +LodeTest`: python3 test/lsp.py
For a source/path-override workspace, pass --lean-path with its built module
search path to run Lean directly, without changing dependency pins/manifests.
No network, repository commits or mock-only success criterion.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


SOURCE = """/-- Increment a natural number. -/
def lspTarget (n : Nat) : Nat := n + 1
def lspUse := lspTarget 4
theorem lspGoal : True := by
  trivial
def emojiUse := ("😀", lspTarget 1)
"""


def frame_read():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise EOFError
        if line == b"\r\n":
            break
        key, value = line.decode().strip().split(": ", 1)
        headers[key] = value
    return json.loads(sys.stdin.buffer.read(int(headers["Content-Length"])))


def frame_write(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    sys.stdout.buffer.flush()


def server_shim():
    """PATH-only fixture; production's command/method surface is unchanged."""
    marker = Path(os.environ["LSP_MARKER"])
    secrets = [key for key in os.environ if key in (
        "LODE_TOKEN", "LODE_MODEL_API_KEY", "LODE_LUN_TOKEN", "LODE_LIAISON_URL")]
    marker.write_text(json.dumps({"pid": os.getpid(), "args": sys.argv[2:], "secrets": secrets}))
    mode = os.environ.get("LSP_TEST_MODE", "real")
    if mode == "real":
        os.execv(os.environ["LSP_REAL_LAKE"], [os.environ["LSP_REAL_LAKE"], *sys.argv[2:]])
    # Every adversarial fixture has a live descendant holding the pipes. Cleanup
    # must kill the whole group, including on protocol failure and success.
    child = os.fork()
    if child == 0:
        time.sleep(60)
        os._exit(0)
    Path(str(marker) + ".child").write_text(str(child))
    frame_read()
    if mode == "timeout":
        time.sleep(60)
    elif mode == "partial":
        sys.stdout.buffer.write(b"Content-Length: 100\r\n\r\n{")
        sys.stdout.buffer.flush()
        time.sleep(60)
    elif mode == "write_block":
        frame_write({"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}})
        # Never read didOpen: a large validated document fills the input pipe.
        time.sleep(60)
    elif mode == "stderr_flood":
        sys.stderr.buffer.write(b"x" * 1048576)
        sys.stderr.buffer.flush()
        time.sleep(60)
    elif mode == "oversize":
        sys.stdout.buffer.write(b"Content-Length: 262145\r\n\r\n")
    elif mode == "long_header":
        sys.stdout.buffer.write(b"x" * 2048)
    elif mode == "duplicate":
        sys.stdout.buffer.write(b"Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}")
    elif mode == "bad_json":
        sys.stdout.buffer.write(b"Content-Length: 2\r\n\r\n{{")
    elif mode == "bad_utf8":
        sys.stdout.buffer.write(b"Content-Length: 2\r\n\r\n\xff\xff")
    elif mode == "nested":
        data = ("[" * 65 + "]" * 65).encode()
        sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    elif mode == "exponent":
        data = b'{"jsonrpc":"2.0","id":1,"result":1e999999999999999999}'
        sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    elif mode == "number":
        data = b'{"jsonrpc":"2.0","id":1,"result":' + b'1' * 1000 + b'}'
        sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
    elif mode == "server_command":
        frame_write({"jsonrpc": "2.0", "id": 77, "method": "workspace/applyEdit", "params": {}})
    elif mode == "wrong_id":
        frame_write({"jsonrpc": "2.0", "id": 88, "result": {}})
    elif mode == "wrong_version":
        frame_write({"jsonrpc": "1.0", "id": 1, "result": {}})
    elif mode == "mixed_envelope":
        frame_write({"jsonrpc": "2.0", "id": 1, "method": "workspace/applyEdit", "result": {}})
    elif mode == "mixed_result":
        frame_write({"jsonrpc": "2.0", "id": 1, "result": {}, "error": {"message": "EXTERNAL-SECRET"}})
    elif mode == "flood":
        for _ in range(300):
            frame_write({"jsonrpc": "2.0", "method": "ignored", "params": {}})
    elif mode == "wire_budget":
        for _ in range(8):
            frame_write({"jsonrpc": "2.0", "method": "ignored", "params": {"text": "x" * 180000}})
    else:
        frame_write({"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}})
        initialized = frame_read()
        opened = frame_read()
        barrier = frame_read()
        assert initialized["method"] == "initialized"
        assert opened["method"] == "textDocument/didOpen"
        assert opened["params"]["dependencyBuildMode"] == "never"
        assert barrier["method"] == "textDocument/waitForDiagnostics"
        uri = opened["params"]["textDocument"]["uri"]
        frame_write({"jsonrpc": "2.0", "id": "register_lean_watcher", "method": "client/registerCapability", "params": {}})
        frame_write({"jsonrpc": "2.0", "id": 2, "method": "workspace/inlayHint/refresh"})
        frame_write({"jsonrpc": "2.0", "id": 2, "method": "workspace/semanticTokens/refresh"})
        r = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}
        if mode == "diagnostics_projection":
            for target, version, message in [("file:///private/Secret.lean", 1, "EXTERNAL-SECRET"),
                                              (uri, 0, "STALE-SECRET"), (uri, 1, "first")]:
                frame_write({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
                    "uri": target, "version": version, "diagnostics": [{"range": r, "message": message}]}})
            frame_write({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {
                "uri": uri, "version": 1, "isIncremental": True,
                "diagnostics": [{"range": r, "message": "second", "data": {"secret": "HIDDEN-DATA"},
                    "relatedInformation": [{"location": {"uri": "file:///private/Secret.lean", "range": r},
                        "message": "RELATED-SECRET"}]}]}})
        frame_write({"jsonrpc": "2.0", "id": 2, "result": {}})
        if mode != "diagnostics_projection":
            query = frame_read()
            assert query["method"] in ["textDocument/hover", "textDocument/definition", "textDocument/completion", "$/lean/plainGoal"]
            assert query["params"]["textDocument"]["uri"] == uri
            if mode == "definition_projection":
                result = [{"targetUri": target, "targetRange": r, "targetSelectionRange": r} for target in (
                    uri, "file:///private/Secret.lean", os.environ["LSP_OUTSIDE_URI"],
                    os.environ["LSP_SYMLINK_URI"], os.environ["LSP_SIBLING_URI"],
                    "file:///private/%FF.lean", "file:///private/%00.lean", "file:///private/%GG.lean",
                    "file://external-host/private/Secret.lean")]
            elif mode == "completion_projection":
                result = {"isIncomplete": False, "items": [{"label": "lspTarget", "kind": 3,
                    "command": {"command": "dangerous"}, "data": {"uri": "file:///private/Secret.lean"},
                    "textEdit": {"newText": "UNAUTHORIZED-EDIT", "insert": r, "replace": r}}]}
            elif mode == "result_budget":
                result = {"isIncomplete": False, "items": [{"label": "x" * 11000}] * 8}
            else:
                result = {"contents": {"kind": "markdown", "value": "[secret](file:///private/Secret.lean)"}}
            frame_write({"jsonrpc": "2.0", "id": 3, "result": result})
    sys.stdout.buffer.flush()
    time.sleep(60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-path", help="built Lode/Linen/Liaison search path; bypass Lake workspace load")
    opts = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    real_lake = shutil.which("lake")
    assert real_lake, "lake is required"
    prefix = subprocess.check_output(["lean", "--print-prefix"], cwd=repo, text=True).strip()
    lean_path = opts.lean_path or subprocess.check_output(
        [real_lake, "env", "printenv", "LEAN_PATH"], cwd=repo, text=True).strip()
    # Bypass Elan's proxy: it prepends the toolchain bin directory to PATH,
    # which would hide the adversarial test shim from the worker.
    command = [str(Path(prefix) / "bin" / "lean"), "--run", "test/LspSmoke.lean"]
    count = 0
    with tempfile.TemporaryDirectory(prefix="lode-lsp-") as temporary:
        work = Path(temporary)
        checkout = work / "checkout"
        project = checkout / "lean"
        project.mkdir(parents=True)
        (project / "lakefile.toml").write_text('name = "lspfixture"\n[[lean_lib]]\nname = "Demo"\n')
        (project / "lean-toolchain").write_text((repo / "lean-toolchain").read_text())
        (project / "Demo.lean").write_text(SOURCE)
        (project / "Bad.lean").write_text('def bad : Nat := "not a Nat"\n')
        outside = work / "Outside.lean"
        outside.write_text("def outsideSecret := 42\n")
        (project / "escape.lean").symlink_to(outside)
        (project / "inside.lean").symlink_to(project / "Demo.lean")
        sibling = work / "checkout-evil"
        sibling.mkdir()
        (sibling / "Secret.lean").write_text("def siblingSecret := 43\n")
        (project / "invalid.lean").write_bytes(b"\xff")
        (project / "oversize.lean").write_bytes(b" " * 1048577)
        (project / "Large.lean").write_text("/-" + "x" * 400000 + "-/\n")
        (project / "dir.lean").mkdir()
        (project / "pipe.lean").touch()
        (project / "pipe.lean").unlink()
        os.mkfifo(project / "pipe.lean")
        (project / "spaces résumé.lean").write_text(SOURCE)
        for hidden in [".git", ".lake"]:
            (project / hidden).mkdir()
            (project / hidden / "Hidden.lean").write_text(SOURCE)
        (project / "bookkeeping.lean").symlink_to(project / ".lake" / "Hidden.lean")
        shim = work / "bin"
        shim.mkdir()
        (shim / "lake").write_text(f'#!{sys.executable}\nimport os\nos.execv({sys.executable!r}, [{sys.executable!r}, {str(Path(__file__).resolve())!r}, "--server-shim", *os.sys.argv[1:]])\n')
        (shim / "lake").chmod(0o755)
        marker = work / "started.json"
        env = os.environ.copy()
        env["LEAN_PATH"] = lean_path
        env.update({"LSP_MARKER": str(marker), "LSP_REAL_LAKE": real_lake,
                    "LSP_OUTSIDE_URI": outside.as_uri(), "LSP_SYMLINK_URI": (project / "escape.lean").as_uri(),
                    "LSP_SIBLING_URI": (sibling / "Secret.lean").as_uri(),
                    "LODE_TOKEN": "MUST-NOT-REACH-SERVER", "LODE_MODEL_API_KEY": "MUST-NOT-REACH-SERVER",
                    "LODE_LUN_TOKEN": "MUST-NOT-REACH-SERVER", "LODE_LIAISON_URL": "MUST-NOT-REACH-SERVER"})
        env["PATH"] = str(shim) + os.pathsep + env["PATH"]

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False

        def call(operation="hover", path="Demo.lean", line=2, character=16, mode="real", **settings):
            nonlocal count
            marker.unlink(missing_ok=True)
            child_marker = Path(str(marker) + ".child")
            child_marker.unlink(missing_ok=True)
            args = {"operation": operation, "path": path}
            if operation != "diagnostics":
                args.update(line=line, character=character)
            args.update(settings.pop("extra_args", {}))
            request = {"root": str(checkout), "project": ["lean"], "timeoutMs": 30000,
                       "policy": ["lsp"], "agent": ["lsp"], "arguments": args, **settings}
            started = time.monotonic()
            ran = subprocess.run(command, cwd=repo, input=json.dumps(request) + "\n", text=True,
                                 capture_output=True, env={**env, "LSP_TEST_MODE": mode}, timeout=40)
            assert ran.returncode == 0, (ran.stdout, ran.stderr)
            result = json.loads(ran.stdout)
            if not result["isError"]:
                assert marker.exists(), "successful query bypassed the tracked lake worker"
            if marker.exists():
                spawn = json.loads(marker.read_text())
                assert spawn["args"] == ["serve"], spawn
                assert spawn["secrets"] == [], spawn
                pids = [spawn["pid"]]
                if child_marker.exists():
                    pids.append(int(child_marker.read_text()))
                until = time.monotonic() + 2
                while any(alive(pid) for pid in pids) and time.monotonic() < until:
                    time.sleep(0.02)
                assert not any(alive(pid) for pid in pids), f"leaked process group: {pids}"
            count += 1
            return result, time.monotonic() - started

        def ok(**kwargs):
            result, _ = call(**kwargs)
            assert not result["isError"], result
            return json.loads(result["content"])["result"]

        def denied(no_spawn=False, **kwargs):
            result, duration = call(**kwargs)
            assert result["isError"], (kwargs, result)
            assert len(result["content"].encode()) <= 50000
            if no_spawn:
                assert not marker.exists(), (kwargs, result)
            return result, duration

        # Real installed server: these cannot be satisfied by the pipe fixture.
        diagnostics = ok(operation="diagnostics", path="Bad.lean")
        assert any("Nat" in d["message"] and d["severity"] == 1 for d in diagnostics), diagnostics
        assert ok(operation="diagnostics") == []
        hover = ok()
        assert "lspTarget" in hover["text"] and "Nat" in hover["text"], hover
        definition = ok(operation="definition")
        assert any(d["path"] == "lean/Demo.lean" and d["range"]["start"]["line"] == 1
                   for d in definition["locations"]), definition
        completions = ok(operation="completion", character=18)
        assert any(item["label"] == "lspTarget" for item in completions["items"]), completions
        goals = ok(operation="goals", line=4, character=2)
        assert any("True" in goal for goal in goals["goals"]), goals
        prefix = SOURCE.splitlines()[5].split("lspTarget")[0]
        utf16 = len(prefix.encode("utf-16-le")) // 2
        assert "lspTarget" in ok(line=5, character=utf16 + 3)["text"]
        assert "lspTarget" in ok(path="inside.lean")["text"]
        assert "lspTarget" in ok(path="spaces résumé.lean")["text"]
        assert ok(operation="definition", line=1, character=21)["omitted"] > 0
        print("PASS: real diagnostics, hover, completion, definition, goals and UTF-16 positions")

        # A graph-shaped pipeline: a child requires String while its unpinned
        # parent's inferred output is Nat. LSP locates the mismatch; changing
        # only the parent implementation coherently makes the graph type-check.
        graph_doc=project/"Graph.lean"
        graph_doc.write_text('def parent (n : Nat) : Nat := n\ndef child (n : String) : Nat := n.length\ndef graph (n : Nat) : Nat := child (parent n)\n')
        errors=ok(operation="diagnostics",path="Graph.lean")
        assert any(d["severity"]==1 for d in errors),errors
        graph_doc.write_text('def parent (n : Nat) : String := toString n\ndef child (n : String) : Nat := n.length\ndef graph (n : Nat) : Nat := child (parent n)\n')
        assert ok(operation="diagnostics",path="Graph.lean")==[]
        graph_doc.write_text('def parent (n : Nat) : Nat := toString n\ndef child (n : String) : Nat := n.length\ndef graph (n : Nat) : Nat := child (parent n)\n')
        assert any(d["severity"]==1 for d in ok(operation="diagnostics",path="Graph.lean"))
        print("PASS: real Lean LSP diagnoses graph argument mismatch, accepts unpinned parent output changes and rejects a conflicting fixed output annotation")

        # Denials traverse the actual dispatcher and must not even start Lake.
        denied(policy=[], no_spawn=True)
        denied(agent=["read"], no_spawn=True)
        denied(aborted=True, no_spawn=True)
        denied(operation="rpc", no_spawn=True)
        for field, value in [("method", "workspace/executeCommand"), ("uri", outside.as_uri()),
                             ("params", {}), ("text", "#eval IO.println 1"), ("command", "false")]:
            denied(extra_args={field: value}, no_spawn=True)
        for path in [str(outside), "../Outside.lean", "A/../Demo.lean", "file:///tmp/A.lean", "A%2fB.lean",
                     "escape.lean", "invalid.lean", "oversize.lean", "dir.lean", "pipe.lean", "missing.lean"]:
            denied(path=path, no_spawn=True)
        for path in [".git/Hidden.lean", ".lake/Hidden.lean", "bookkeeping.lean", "x" * 4097 + ".lean"]:
            denied(path=path, no_spawn=True)
        denied(line=9999, no_spawn=True)
        denied(character=-1, no_spawn=True)
        denied(line=5, character=len('def emojiUse := ("'.encode("utf-16-le")) // 2 + 1, no_spawn=True)
        denied(project=["..", "checkout-evil"], no_spawn=True)
        print("PASS: policy/agent denials and document/position confinement without subprocesses")

        for mode in ["oversize", "long_header", "duplicate", "bad_json", "bad_utf8", "nested",
                     "exponent", "number", "server_command", "wrong_id", "wrong_version", "mixed_envelope",
                     "mixed_result", "flood", "wire_budget"]:
            denied(mode=mode, timeoutMs=3000)
        for mode in ["timeout", "partial"]:
            result, duration = denied(mode=mode, timeoutMs=200)
            assert "timed out" in result["content"] and duration < 5, (result, duration)
        for mode in ["write_block", "stderr_flood"]:
            result, duration = denied(mode=mode, operation="diagnostics", path="Large.lean", timeoutMs=200)
            assert "timed out" in result["content"] and duration < 5, (result, duration)
        result, duration = denied(mode="timeout", timeoutMs=10000, abortAfterMs=200)
        assert "aborted" in result["content"] and duration < 5, (result, duration)
        print("PASS: framing/JSON/size/notification limits, abort/timeout and process-group cleanup")

        definition = ok(operation="definition", mode="definition_projection")
        assert definition["omitted"] == 8 and len(definition["locations"]) == 1, definition
        completion = ok(operation="completion", mode="completion_projection")
        assert set(completion["items"][0]) == {"label", "detail", "kind"}, completion
        diagnostics = ok(operation="diagnostics", mode="diagnostics_projection")
        assert [d["message"] for d in diagnostics] == ["first", "second"], diagnostics
        assert "Secret" not in json.dumps(diagnostics), diagnostics
        hover = ok(mode="hover_projection")
        assert "Secret" not in hover["text"] and "omitted" in hover["text"], hover
        denied(operation="completion", mode="result_budget")
        print(f"PASS: data-only projections and output confinement; {count} dispatcher calls")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--server-shim":
        server_shim()
    else:
        main()
