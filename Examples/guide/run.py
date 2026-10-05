#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["rich>=13"]
# ///

"""Generate, check, publish and run a Lean/Lun project with a scripted Lode model."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT))
from Examples.client import ApiError, Client  # noqa: E402


def command(args, cwd):
    """Keep build/setup progress on stderr; demo requests/replies go to stdout."""
    subprocess.run(args, cwd=cwd, check=True, stdout=sys.stderr, stderr=sys.stderr)


class LocalServer:
    """Own a disposable service and its subprocess group, including on failure."""

    def __init__(self, binary, directory, prefix, environment):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.client = Client(f"http://127.0.0.1:{port}", "guide-local")
        self.log = (directory / (prefix.lower() + ".log")).open("w")
        self.process = None
        env = {key: value for key, value in os.environ.items() if not key.startswith(("LODE_", "LUN_"))}
        env.update(environment)
        env.update({prefix + "_PORT": str(port), prefix + "_TOKEN": "guide-local",
                    prefix + "_ALLOW_LOCAL": "1", prefix + "_WORKDIR": str(directory / prefix.lower())})
        try:
            self.process = subprocess.Popen([str(binary), "serve"], env=env, cwd=ROOT,
                                            stdout=self.log, stderr=self.log, start_new_session=True)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"{prefix} exited; see {self.log.name}")
                try:
                    if self.client.request("GET", "/_health", timeout=1)["status"] == 200:
                        break
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.1)
            else:
                raise TimeoutError(f"{prefix} did not become healthy; see {self.log.name}")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process is not None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.log.close()

    def __enter__(self):
        return self.client

    def __exit__(self, *args):
        self.close()


def seed_repository(work):
    """Only a README and ignore file exist initially; Lode writes the project."""
    seed = work / "seed"
    seed.mkdir()
    (seed / "README.md").write_text("# Generated Lean/Lun project\n", encoding="utf-8")
    (seed / ".gitignore").write_text(".lake/\n", encoding="utf-8")
    command(["git", "init", "-q", "-b", "main"], seed)
    command(["git", "add", "README.md", ".gitignore"], seed)
    command(["git", "-c", "user.name=Guide", "-c", "user.email=guide@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-qm", "Seed an empty project"], seed)
    remote = work / "project.git"
    command(["git", "clone", "-q", "--bare", str(seed), str(remote)], work)
    return remote


def project_files(linen):
    """The deterministic model's write arguments; nothing is preloaded into Git."""
    files = {str(path.relative_to(HERE / "project")): path.read_text(encoding="utf-8")
             for path in sorted((HERE / "project").rglob("*.lean"))}
    files["lean-toolchain"] = (ROOT / "lean-toolchain").read_text(encoding="utf-8")
    # Local-only path dependency reuses Linen's compiled library in both services.
    # For a portable project use a Git revision and commit its resolved lock.
    files["lakefile.toml"] = ('name = "lode_guide"\ndefaultTargets = ["Demo", "Demo.Wiring"]\n\n'
                              '[[require]]\nname = "linen"\npath = ' + json.dumps(str(linen)) + '\n\n'
                              '[[lean_lib]]\nname = "Demo"\n')
    files["lun.json"] = (HERE / "lun.json").read_text(encoding="utf-8")
    return files


def turn(text, *calls):
    return {"text": text, "calls": [{"name": name, "arguments": args} for name, args in calls]}


def script(files):
    """Assistant turns use the actual tool dispatcher, compiler, Git and Lun."""
    good = files["lun.json"]
    broken = json.loads(good)
    broken["graphs"][0]["program"] = broken["graphs"][0]["program"].replace('add doubled base', 'add doubled "oops"')
    first = {**files, "lun.json": json.dumps(broken, ensure_ascii=False, indent=2) + "\n"}
    return [
        turn("Create the Lake project, functions and declarations.",
             *(("write", {"path": path, "content": content}) for path, content in first.items())),
        turn("Resolve and lock the only project dependency.", ("bash", {"command": "lake update"})),
        turn("Check payload types with the compiler and Lean LSP.", ("check", {}),
             ("lsp", {"operation": "diagnostics", "path": "Demo/Wiring.lean"}),
             ("lsp", {"operation": "hover", "path": "Demo.lean", "line": 6, "character": 4})),
        turn("Publish, then demonstrate Lun's graph-specific type diagnostic.",
             ("publish", {"message": "Generate Lean services and a graph"}), ("lun_build", {})),
        turn("Repair the graph argument and rebuild the published version.",
             ("write", {"path": "lun.json", "content": good}), ("check", {}),
             ("publish", {"message": "Fix the basket graph argument"}), ("lun_build", {})),
        turn("Try the compiled functions and graph using input data only.",
             ("lun_call", {"kind": "function", "name": "double", "body": {"input": 21}}),
             ("lun_call", {"kind": "function", "name": "add", "body": {"input": [7, 8]}}),
             ("lun_call", {"kind": "function", "name": "seed", "body": {}}),
             ("lun_call", {"kind": "graph", "name": "basket", "body": {"inputs": {"value": 5}}})),
        {"text": "Published a checked Lean project: double, add, seed and basket. Lun's final build is ready."},
    ]


def run_example(client, lun, remote, linen, console, quiet, real_model):
    checks = 0

    def check(condition, detail):
        nonlocal checks
        if not condition:
            raise AssertionError(detail)
        checks += 1

    def show(title, data):
        if not quiet:
            console.rule(title)
            console.print_json(data=data, ensure_ascii=False)

    # These types/wiring are caller-owned, independent of model-written lun.json.
    spec = {"source": {"url": remote.as_uri(), "branch": "main"},
            "tools": ["read", "ls", "grep", "write", "edit", "bash", "todo", "check", "lsp",
                      "publish", "lun_build", "lun_call"],
            "buildContracts": {"outputs": {"double": "Nat", "add": "Nat", "seed": "Nat"},
                               "graph": "basket", "inputs": {"value": "Nat"},
                               "dependencies": {"double": ["value"], "seed": [], "add": ["double", "seed"]}}}
    if not real_model:
        spec["model"] = {"api": "scripted", "script": script(project_files(linen))}
    # Keep creation separate from the first task, as required by brokered launch.
    created = client.create(spec)
    session = created["id"]
    show("Create the session", created)
    task = (f"Create a complete Lean project using {linen} as the local Linen path dependency and this "
            "server's Lean toolchain. Implement Demo.double : Nat → Eff [] Nat (twice n), "
            "Demo.add : Nat → Nat → Eff [] Nat (sum), Demo.seed : Unit → Eff [] Nat (constant 10). "
            "Declare them as double/add/seed in lun.json, and a basket graph with Nat input value, "
            "double value, seed, then add the two results. Keep the caller's output/input/wiring pins. "
            "Include a Demo/Wiring.lean payload-type check; use check and Lean LSP diagnostics/hover. "
            "Run lake update and publish its lock with all sources and lun.json. lun_build, fix any "
            "diagnostics with a new publication/build, and lun_call all services: double(21)=42, "
            "add(7,8)=15, seed()=10, basket(value=5)=20. Finish with the commit and ready build ID.")
    show("Submit the task", client.send(session, task))

    # Save entries before validating outcomes: idle and a normal answer alone are
    # insufficient. In a question-capable client, save the cursor and answer the
    # actual pending question before following again.
    entries = []
    for entry in client.follow(session):
        entries.append(entry)
        show(f"Lode log entry {entry['index']}", entry)
    status = client.status(session)
    show("Final Lode status", status)
    check(status["state"] == "idle" and not status["error"] and not status["question"], status)
    events = [entry["kind"] for entry in entries if entry["type"] == "event"]
    check(bool(events) and events[-1] == "run_finished", events)
    results = [result for entry in entries if entry["type"] == "tool_results" for result in entry["results"]]
    errors = [result for result in results if result["isError"]]
    if not real_model:
        # The one deliberate error must come from compiling the embedded graph.
        check(len(errors) == 1 and errors[0]["name"] == "lun_build"
              and "[graph basket]" in errors[0]["content"], errors)
        calls = [json.loads(result["content"]) for result in results if result["name"] == "lun_call"]
        check([call["output"] for call in calls[:3]] == [42, 15, 10], calls)
        check(calls[3]["nodes"][-1]["output"] == 20, calls[3])
    diagnostics = [json.loads(result["content"]) for result in results
                   if result["name"] == "lsp" and not result["isError"]]
    check(any(d["operation"] == "diagnostics" and not d["result"] for d in diagnostics), diagnostics)
    check(any(d["operation"] == "hover" and d["result"] for d in diagnostics), diagnostics)
    source_checks = [r for r in results if r["name"] == "check"]
    check(bool(source_checks) and not source_checks[-1]["isError"]
          and "Build succeeded" in source_checks[-1]["content"], source_checks)
    check(client.diff(session).strip() == "", "Expected every change to be published")

    # Check the shared Git artifact, rather than trusting the assistant's summary.
    head = subprocess.check_output(["git", "-C", str(remote), "rev-parse", "main"], text=True).strip()
    check(head == status["workspace"]["remoteHead"], status["workspace"])
    for path in ("Demo.lean", "Demo/Wiring.lean", "lakefile.toml", "lean-toolchain", "lake-manifest.json", "lun.json"):
        content = subprocess.check_output(["git", "-C", str(remote), "show", "main:" + path], text=True)
        check(bool(content.strip()), f"Missing published artifact: {path}")

    build = status["lastBuild"]
    check(isinstance(build, str) and len(build) == 64, status)
    base = "/v0/builds/" + build

    def runtime(title, method, path, body=None):
        reply = lun.request(method, path, body)
        show(title, reply)
        check(reply["status"] == 200, reply)
        return reply["body"]

    built = runtime("Inspect Lun's compiled functions and graph topology", "GET", base)
    check(built["state"] == "ready" and built["source"]["commit"] == head, built)
    check(runtime("Call double directly", "POST", base + "/functions/double", {"input": 21})["output"] == 42,
          "double(21) must be 42")
    check(runtime("Call add directly", "POST", base + "/functions/add", {"input": [7, 8]})["output"] == 15,
          "add(7,8) must be 15")
    check(runtime("Call seed directly", "POST", base + "/functions/seed", {})["output"] == 10,
          "seed() must be 10")
    graph = runtime("Initialize basket; retain the returned state in Python", "POST", base + "/graphs/basket",
                    {"inputs": {"value": 5}, "now": 1000})
    check(graph["nodes"][-1]["output"] == 20 and graph["nextCallAt"] is None, graph)
    # Lun execution state belongs to this client, not the Lode writing session.
    updated = runtime("Resume basket with a new input", "POST", base + "/graphs/basket",
                      {"inputs": {"value": 8}, "state": graph["state"], "now": 2000})
    check(updated["nodes"][-1]["output"] == 26
          and [n.get("function", n.get("input")) for n in updated["changed"]] == ["value", "double", "add"], updated)
    unchanged = runtime("An unchanged input does no new work", "POST", base + "/graphs/basket",
                        {"inputs": {"value": 8}, "state": updated["state"], "now": 3000})
    check(unchanged["changed"] == [], unchanged)
    console.print(f"{checks} checks passed: generated Lean project and Lun graph; commit {head}; build {build}.",
                  markup=False, soft_wrap=True)


def main():
    from rich.console import Console

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lun", type=Path, default=ROOT.parent / "lun", help="Lun source checkout")
    parser.add_argument("--linen", type=Path, default=ROOT / ".lake/packages/linen", help="coordinated local Linen checkout")
    parser.add_argument("--real-model", action="store_true", help="use inherited LODE_MODEL_* defaults instead of scripted turns")
    parser.add_argument("--skip-build", action="store_true", help="use already-built Lode and Lun binaries")
    parser.add_argument("--quiet", action="store_true", help="print just setup progress and the verification summary")
    parser.add_argument("--keep", action="store_true", help="keep the bare repository, service state and logs")
    parser.add_argument("--temp-root", type=Path, default=Path("/tmp"), help="existing scratch directory with plain path components")
    args = parser.parse_args()
    lun_root, linen = args.lun.resolve(), args.linen.resolve()
    if not args.skip_build:
        command(["lake", "build", "lode"], ROOT)
        command(["lake", "build", "lun"], lun_root)
    with ExitStack() as stack:
        if args.keep:
            work = Path(tempfile.mkdtemp(prefix="lode-guide-", dir=args.temp_root.resolve()))
        else:
            work = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="lode-guide-", dir=args.temp_root.resolve())))
        print(f"Demo directory: {work}", file=sys.stderr)
        remote = seed_repository(work)
        sdk = lun_root / ".lake/packages/liaison"
        if not (linen / "lakefile.lean").is_file() or not (sdk / "Liaison/Wire.lean").is_file():
            raise RuntimeError("Build the coordinated Linen/Liaison dependencies before running the example")
        lun = stack.enter_context(LocalServer(lun_root / ".lake/build/bin/lun", work, "LUN",
                                              {"LUN_ID_SALT": "lode-guide", "LUN_LIAISON_SDK_PATH": str(sdk)}))
        model_env = {k: v for k, v in os.environ.items() if k.startswith("LODE_MODEL_")} if args.real_model else {}
        client = stack.enter_context(LocalServer(ROOT / ".lake/build/bin/lode", work, "LODE",
                                                 {**model_env, "LODE_LUN_URL": lun.base_url, "LODE_LUN_TOKEN": "guide-local"}))
        run_example(client, lun, remote, linen, Console(), args.quiet, args.real_model)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, ApiError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"lode guide: {error}", file=sys.stderr)
        sys.exit(1)
