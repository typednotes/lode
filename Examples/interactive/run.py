#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["rich>=13"]
# ///

"""Chat with local Lode, then try its published functions and graphs in Lun."""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from Examples.client import ApiError  # noqa: E402
from Examples.graph_svg import open_svg, render_graph, write_graphs  # noqa: E402
from Examples.guide.run import LocalServer, command, project_files, script, seed_repository, turn  # noqa: E402

LODE_HELP = """Type a task for Lode (--real-model), or use:
  /demo     Generate double, add, seed and the basket graph
  /lun      Open the interactive Lun prompt for the latest published build
  /status   Inspect the Lode session
  /diff     Inspect unpublished changes
  /follow   Continue following a run or answer a pending question
  /abort    Cancel work or a pending question
  /help     Show these commands
  /quit     Stop the local services and exit
Ctrl-C during a run requests cancellation. Ctrl-D exits."""

LUN_HELP = """Lun commands (JSON is entered directly, without shell quoting):
  function NAME [JSON]   Call a function; omit JSON for a Unit input
  graph NAME JSON        Set graph inputs, retaining its returned state
  next NAME              Advance a graph's demo clock to nextCallAt
  show [NAME]            Show the build or a graph's latest reply
  svg [NAME]             Save graph SVGs (all graphs if NAME is omitted)
  viz [NAME]             Save SVGs and open them in the default browser
  reset NAME             Discard a graph's state before its next call
  help                   Show these commands
  back                   Return to Lode to request changes
Examples: function double 21 | function add [7,8] | function seed
          graph basket {"value":5} | graph basket {"value":8}
Each graph has its own saved state and explicit clock, initially 1000 ms.
next advances that clock immediately; it does not sleep."""

# Fake keyboard input, through the same prompts and dispatch as an interactive
# user. Model replies are fixtures; Git, Lean, question handling and Lun are real.
DEMO_LINES = [
    "/demo", "1", "/lun", "svg basket", "function double 21", "function add [7,8]", "function seed",
    'graph basket {"value":5}', 'graph basket {"value":8}', 'graph basket {"value":8}',
    'graph basket {"value":', 'graph basket {"value":8}',
    'graph basket {"value":-1}', 'graph basket {"value":8}',
    "reset basket", 'graph basket {"value":5}', "next basket", "show basket", "viz basket", "back", "/quit",
]


class Terminal:
    """Use real stdin, or a reproducible sequence of keyboard input for --demo."""

    def __init__(self, console, demo=False):
        self.console = console
        self.lines = iter(DEMO_LINES) if demo else None
        self.replies = [] if demo else None
        self.answers = 0

    def read(self, prompt):
        print(prompt, end="", file=sys.stderr, flush=True)
        if self.lines is not None:
            try:
                line = next(self.lines)
            except StopIteration:
                raise AssertionError("The interactive demo unexpectedly asked for more input") from None
            print(line, file=sys.stderr)
            return line
        line = sys.stdin.readline()
        if not line:
            raise EOFError()
        return line.strip()

    def say(self, text):
        self.console.print(text, markup=False, soft_wrap=True)

    def show(self, data):
        self.console.print_json(data=data, ensure_ascii=False)


def request(lun, terminal, method, path, body=None):
    """Display runtime refusals, and never treat an HTTP error as a result."""
    reply = lun.request(method, path, body)
    terminal.show(reply)
    if not 200 <= reply["status"] < 300:
        raise ApiError(reply)
    return reply["body"]


class LunPrompt:
    """The client owns graph continuations, scoped to an immutable build ID."""

    def __init__(self, lun, terminal, svg_dir=None, open_browser=True):
        self.lun = lun
        self.terminal = terminal
        self.snapshots = {}
        self.svg_dir, self.open_browser = svg_dir, open_browser
        self.builds, self.exports = {}, {}

    def refresh_svg(self, build, name):
        """Once exported, a graph's SVG follows subsequent outcomes and resets."""
        path = self.exports.get((build, name))
        if path is not None:
            built = self.builds[build]
            graph = next(graph for graph in built["graphs"] if graph["name"] == name)
            path.write_text(render_graph(graph, build=built, snapshot=self.snapshots.get((build, name))), encoding="utf-8")

    def export(self, built, name, browse=False):
        if self.svg_dir is None:
            raise ValueError("An SVG output directory is required")
        build = built["id"]
        graphs = [graph for graph in (built.get("graphs") or []) if not name or graph["name"] == name]
        snapshots = {graph["name"]: self.snapshots.get((build, graph["name"])) for graph in graphs}
        paths = write_graphs(built, self.svg_dir / build, snapshots=snapshots, name=name or None)
        for graph, path in zip(graphs, paths):
            self.exports[build, graph["name"]] = path
            self.terminal.say("SVG: " + path.as_uri())
            if browse:
                if not self.open_browser:
                    self.terminal.say("Browser opening disabled; open the file URI manually.")
                elif not open_svg(path):
                    self.terminal.say("Could not open the browser; open the file URI manually.")

    def step(self, build, name, inputs, now=None):
        previous = self.snapshots.get((build, name))
        if now is None:
            now = previous["state"]["now"] if previous else 1000
        body = {"inputs": inputs, "now": now, "state": previous["state"] if previous else None,
                "binding": {"org_id": "local", "user_id": "developer", "graph_id": name},
                "policy": {"effects": [], "domains": []}}
        result = request(self.lun, self.terminal, "POST", self.path(build, "graphs", name), body)
        # HTTP refusals do not replace state; graph node errors are outcomes in
        # a successful step and its continuation is retained for the next update.
        self.snapshots[build, name] = result
        self.refresh_svg(build, name)
        return result

    @staticmethod
    def path(build, kind, name):
        return f"/v0/builds/{build}/{kind}/" + urllib.parse.quote(name, safe="")

    def run(self, status):
        build = status.get("lastBuild")
        if not build:
            raise ValueError("No Lun build yet. Ask Lode to check, publish and lun_build first.")
        built = request(self.lun, self.terminal, "GET", "/v0/builds/" + build)
        if built["state"] != "ready":
            raise ValueError("This Lun build is not ready. Ask Lode to fix the diagnostics and rebuild.")
        if built["source"]["commit"] != status["workspace"]["remoteHead"]:
            raise ValueError("The build is for an older commit. Ask Lode to lun_build the latest publication.")
        self.terminal.say(f"Testing published commit {built['source']['commit']}; build {build}.")
        self.builds[build] = built
        self.terminal.say(LUN_HELP)
        while True:
            try:
                line = self.terminal.read("lun> ")
                op, _, rest = line.partition(" ")
                rest = rest.strip()
                result = None
                if op == "back":
                    return
                if op == "help":
                    self.terminal.say(LUN_HELP)
                elif op == "show":
                    self.terminal.show(self.snapshots[build, rest] if rest else built)
                elif op in ("svg", "viz"):
                    self.export(built, rest, browse=op == "viz")
                elif op == "reset":
                    if not rest:
                        raise ValueError("reset needs a graph name")
                    self.snapshots.pop((build, rest), None)
                    self.refresh_svg(build, rest)
                    self.terminal.say(f"Discarded {rest}'s state. Its next graph call starts fresh.")
                elif op == "function":
                    name, _, text = rest.partition(" ")
                    if not name:
                        raise ValueError("function needs a name and optional JSON input")
                    body = {"input": json.loads(text)} if text.strip() else {}
                    body["binding"] = {"org_id": "local", "user_id": "developer"}
                    body["policy"] = {"effects": [], "domains": []}
                    result = request(self.lun, self.terminal, "POST", self.path(build, "functions", name), body)
                elif op == "graph":
                    name, _, text = rest.partition(" ")
                    inputs = json.loads(text)
                    if not name or not isinstance(inputs, dict):
                        raise ValueError('graph needs a name and JSON input object, e.g. graph basket {"value":5}')
                    result = self.step(build, name, inputs)
                elif op == "next":
                    previous = self.snapshots[build, rest]
                    deadline = previous["nextCallAt"]
                    if deadline is None:
                        self.terminal.say(f"{rest} has no scheduled work.")
                    else:
                        result = self.step(build, rest, {}, deadline)
                elif op:
                    raise ValueError("Unknown Lun command. Use help or back.")
                if result is not None and self.terminal.replies is not None:
                    self.terminal.replies.append(result)
            except KeyError:
                self.terminal.say("That graph has no saved state. Initialize it with graph NAME JSON first.")
            except (ValueError, ApiError, OSError) as error:
                self.terminal.say(str(error))
            except KeyboardInterrupt:
                self.terminal.say("Returning to Lode.")
                return


class LodePrompt:
    """Follow from a saved log cursor and explicitly answer each pending question."""

    def __init__(self, client, lun, session, linen, terminal, real_model, svg_dir=None, open_browser=True):
        self.client, self.session, self.linen = client, session, linen
        self.terminal, self.real_model = terminal, real_model
        self.runtime = LunPrompt(lun, terminal, svg_dir, open_browser)
        self.cursor = 0
        self.demo_started = False

    def question(self, pending):
        question = pending["question"]
        self.terminal.say(question["text"])
        options = question["options"]
        for index, option in enumerate(options, 1):
            self.terminal.say(f"  {index}. {option}")
        self.terminal.say("Enter a choice number" + (" or a text answer" if question["freeText"] else "")
                          + "; /abort cancels, /quit exits.")
        while True:
            answer = self.terminal.read("answer> ")
            if answer == "/quit":
                raise EOFError()
            if answer == "/abort":
                self.terminal.show(self.client.abort(self.session))
                return False
            if answer.isdecimal() and 1 <= int(answer) <= len(options):
                answer = options[int(answer) - 1]
            if not answer or len(answer.encode("utf-8")) > 4096:
                self.terminal.say("Answers must contain 1–4096 UTF-8 bytes.")
                continue
            if not question["freeText"] and answer not in options:
                self.terminal.say("Choose one of the offered answers.")
                continue
            self.client.answer(self.session, pending["id"], answer)
            self.terminal.answers += 1
            return True

    def follow(self):
        try:
            while True:
                for entry in self.client.follow(self.session, after=self.cursor):
                    self.cursor = entry["index"] + 1
                    if entry["type"] == "assistant":
                        if entry["text"]:
                            self.terminal.say("Lode: " + entry["text"])
                        for call in entry["calls"]:
                            self.terminal.say("  tool: " + call["name"])
                    elif entry["type"] == "tool_results":
                        for result in entry["results"]:
                            self.terminal.say(f"  {result['name']} {'ERROR' if result['isError'] else 'OK'}: "
                                              + result["content"])
                    elif entry["type"] == "event":
                        self.terminal.say(entry["kind"] + ": " + entry["detail"])
                status = self.client.status(self.session)
                if status.get("question"):
                    if self.question(status["question"]):
                        continue
                    return
                self.terminal.say(f"Session {status['state']}; checkout {status['checkout']}.")
                if status.get("error"):
                    self.terminal.say("Run error: " + status["error"])
                return
        except KeyboardInterrupt:
            self.client.abort(self.session)
            self.terminal.say("Cancellation requested. /follow waits for it to finish.")
        except TimeoutError:
            self.terminal.say("Client wait timed out; work may still be running. Use /follow or /abort.")

    def demo(self):
        if not self.real_model and self.demo_started:
            raise ValueError("The scripted demo has finished. Use /lun, or restart with --real-model for changes.")
        task = (f"Create a complete Lean project with {self.linen} as a local Linen path dependency. "
                f"Use Lean toolchain {(ROOT / 'lean-toolchain').read_text().strip()}. "
                "Implement Demo.double : Nat → Eff [] Nat (twice n), Demo.add : Nat → Nat → Eff [] Nat "
                "(sum), and Demo.seed : Unit → Eff [] Nat (constant 10). Declare double/add/seed in "
                "lun.json and a basket graph: Nat input value, double value, seed, add both results. "
                "Include a Demo/Wiring.lean payload-type check. Run lake update, check and LSP diagnostics. "
                "Publish all sources, the lock and lun.json, then lun_build; repair diagnostics and "
                "publish/rebuild until ready. Try the functions and graph with lun_call. "
                "Finish with the commit, ready build ID and examples of JSON inputs.")
        self.client.send(self.session, task)
        self.demo_started = True
        self.follow()

    def run(self):
        self.terminal.say(LODE_HELP)
        if not self.real_model:
            self.terminal.say("No-key scripted model: /demo generates a fixed project and asks one question. "
                              "Use --real-model with LODE_MODEL_* for open-ended tasks and revisions.")
        while True:
            try:
                line = self.terminal.read("lode> ")
                if line == "/quit":
                    return
                if line == "/help":
                    self.terminal.say(LODE_HELP)
                elif line == "/demo":
                    self.demo()
                elif line == "/status":
                    self.terminal.show(self.client.status(self.session))
                elif line == "/diff":
                    self.terminal.say(self.client.diff(self.session) or "No unpublished changes.")
                elif line == "/follow":
                    self.follow()
                elif line == "/abort":
                    self.terminal.show(self.client.abort(self.session))
                elif line == "/lun":
                    if self.client.diff(self.session).strip():
                        self.terminal.say("There are unpublished changes. Lun will test the published commit only.")
                    self.runtime.run(self.client.status(self.session))
                elif line.startswith("/"):
                    raise ValueError("Unknown command. Use /help.")
                elif line:
                    if not self.real_model:
                        raise ValueError("Scripted turns do not interpret tasks. Use /demo or restart with --real-model.")
                    context = (f"Local setup: use {self.linen} as the Linen path dependency and "
                               f"{(ROOT / 'lean-toolchain').read_text().strip()} as the Lean toolchain. "
                               "Implement the task, check, publish and lun_build until ready. "
                               "Keep functions pure (Eff []) for this local interactive trial. "
                               "Ask ask_user for necessary decisions. Give JSON input examples.\n\n")
                    self.client.send(self.session, context + line)
                    self.follow()
            except (ValueError, ApiError, OSError) as error:
                self.terminal.say(str(error))
            except KeyboardInterrupt:
                self.terminal.say("Use /quit to exit, or /abort to cancel work.")
            except EOFError:
                self.client.abort(self.session)
                return

    def verify_demo(self):
        status = self.client.status(self.session)
        assert status["state"] == "idle" and status["checkout"] == "ready", status
        assert not status["error"] and not status["question"], status
        assert self.terminal.answers == 1, "The real question/answer flow was not exercised"
        assert not self.client.diff(self.session).strip(), "Unpublished changes remain"
        replies = self.terminal.replies
        assert replies is not None and len(replies) == 10, "Expected three function and seven graph replies"
        assert [reply["output"] for reply in replies[:3]] == [42, 15, 10], replies[:3]
        assert [replies[i]["nodes"][-1]["output"] for i in (3, 4, 5, 6, 8, 9)] == [20, 26, 26, 26, 26, 20]
        assert [node.get("function", node.get("input")) for node in replies[4]["changed"]] == ["value", "double", "add"]
        assert replies[5]["changed"] == replies[6]["changed"] == [], replies[5:7]
        assert any(node.get("function") == "double" and "Natural number expected" in node.get("error", "")
                   for node in replies[7]["nodes"]), replies[7]
        assert replies[7]["nodes"][-1].get("skipped") == 1, replies[7]
        assert not any("error" in node or "skipped" in node for node in replies[8]["nodes"]), replies[8]
        assert any(node.get("function") == "seed" for node in replies[9]["changed"]), replies[9]
        path = self.runtime.exports[status["lastBuild"], "basket"]
        svg = ET.parse(path).getroot()
        ns = {"s": "http://www.w3.org/2000/svg"}
        assert svg.find("s:path[@data-source='2'][@data-target='3'][@data-arg='2']", ns) is not None, path
        assert any(text.text == "Value: 20" for text in svg.findall(".//s:text", ns)), path
        assert next(self.terminal.lines, None) is None, "Demo input was not fully consumed"
        self.terminal.say("Interactive demo passed: background checkout, question/answer, published build, "
                          "function calls, graph updates, invalid-input recovery, state reset and SVG export.")


def main():
    from rich.console import Console

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lun", type=Path, default=ROOT.parent / "lun", help="Lun source checkout (0.4.1+)")
    parser.add_argument("--linen", type=Path, default=ROOT / ".lake/packages/linen", help="coordinated Linen checkout")
    parser.add_argument("--real-model", action="store_true", help="use LODE_MODEL_* for open-ended conversation")
    parser.add_argument("--demo", action="store_true", help="verify the scripted interactive flow and exit")
    parser.add_argument("--skip-build", action="store_true", help="reuse already-built Lode and Lun executables")
    parser.add_argument("--keep", action="store_true", help="retain the Git repository, service state and logs")
    parser.add_argument("--svg-dir", type=Path, help="keep graph SVGs here instead of the disposable demo directory")
    parser.add_argument("--no-browser", action="store_true", help="viz saves SVGs without launching a browser")
    parser.add_argument("--temp-root", type=Path, default=Path("/tmp"), help="existing scratch directory with plain path components")
    args = parser.parse_args()
    if args.real_model and args.demo:
        parser.error("--demo uses scripted turns; omit --real-model")
    if args.real_model and not os.environ.get("LODE_MODEL_NAME"):
        parser.error("--real-model needs LODE_MODEL_*; see docs/user-guide.md section 3")
    lun_root, linen = args.lun.resolve(), args.linen.resolve()
    if not args.skip_build:
        command(["lake", "build", "lode"], ROOT)
        command(["lake", "build", "lun"], lun_root)
    sdk = lun_root / ".lake/packages/liaison"
    if not (linen / "lakefile.lean").is_file() or not (sdk / "Liaison/Wire.lean").is_file():
        raise RuntimeError("Build the coordinated Linen/Liaison dependencies before running the example")
    with ExitStack() as stack:
        if args.keep:
            work = Path(tempfile.mkdtemp(prefix="lode-interactive-", dir=args.temp_root.resolve()))
        else:
            work = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix="lode-interactive-", dir=args.temp_root.resolve())))
        print(f"Demo directory: {work}", file=sys.stderr)
        remote = seed_repository(work)
        lun = stack.enter_context(LocalServer(lun_root / ".lake/build/bin/lun", work, "LUN",
                                              {"LUN_ID_SALT": "lode-interactive", "LUN_LIAISON_SDK_PATH": str(sdk)}))
        model_env = {k: v for k, v in os.environ.items() if k.startswith("LODE_MODEL_")} if args.real_model else {}
        client = stack.enter_context(LocalServer(ROOT / ".lake/build/bin/lode", work, "LODE",
                                                 {**model_env, "LODE_LUN_URL": lun.base_url, "LODE_LUN_TOKEN": "guide-local"}))
        spec = {"source": {"url": remote.as_uri(), "branch": "main"}, "background": True,
                "tools": ["read", "ls", "grep", "write", "edit", "bash", "todo", "check", "lsp",
                          "publish", "lun_build", "lun_call", "ask_user"]}
        if not args.real_model:
            question = turn("Before generating the demo, ask a bounded user question.",
                            ("ask_user", {"text": "Build the double/add/seed and basket example?",
                                          "options": ["Build the demo"], "freeText": False}))
            spec["model"] = {"api": "scripted", "script": [question, *script(project_files(linen))]}
        terminal = Terminal(Console(), args.demo)
        created = client.create(spec)
        terminal.show(created)
        terminal.say(f"Repository: {remote}\nLode: {client.base_url}\nLun: {lun.base_url}")
        svg_dir = args.svg_dir.resolve() if args.svg_dir else work / "graphs"
        prompt = LodePrompt(client, lun, created["id"], linen, terminal, args.real_model,
                            svg_dir, open_browser=not (args.no_browser or args.demo))
        prompt.run()
        if args.demo:
            prompt.verify_demo()


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, ApiError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"lode interactive: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
