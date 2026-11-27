#!/usr/bin/env python3
"""Generate and run a two-input Lean cell using Lode's scripted model."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
INTENT = "Generate an addition cell and a separate Lean program that uses it.\n"
CONSTRAINTS = "Both inputs and the result are natural numbers. The effect row is empty.\n"

CONTRACT = """import Linen.Control.Monad.Effect

namespace Cell
open Control.Monad.Effect

/-- Two natural-number inputs, one natural-number result and no effects. -/
abbrev Addition := Nat → Nat → Eff [] Nat

end Cell
"""

IMPLEMENTATION = """import Cell.Contract

namespace Cell
open Control.Monad.Effect

/-- Add the two inputs without requesting effects. -/
def add : Addition := fun left right => pure (left + right)

/-- Running the cell returns the sum for every pair of inputs. -/
theorem add_correct (left right : Nat) : (add left right).run = left + right := rfl

end Cell
"""

PROGRAM = """import Cell.Addition

open Control.Monad.Effect

/-- Parse two natural numbers and print the result of the imported cell. -/
def main : List String → IO UInt32
  | [left, right] => do
    if let (some left, some right) := (left.toNat?, right.toNat?) then
      IO.println (Cell.add left right).run
      return 0
    else
      IO.eprintln "Both inputs must be natural numbers."
      return 2
  | _ => do
    IO.eprintln "Usage: cell-addition LEFT RIGHT"
    return 2
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".lake/build/bin/lode")
    parser.add_argument("--linen", type=Path, default=ROOT / ".lake/packages/linen")
    parser.add_argument("--output", type=Path, help="Copy the generated source project into a new directory")
    args = parser.parse_args()
    binary, linen = args.binary.resolve(), args.linen.resolve()
    if not binary.is_file() or not linen.is_dir():
        parser.error("build Lode with `lake build lode` or supply --binary and --linen")
    if args.output is not None and args.output.exists():
        parser.error("--output must name a new directory")

    with tempfile.TemporaryDirectory(prefix="lode-cell-addition-") as directory:
        work = Path(directory).resolve()
        seed, remote, project = (work / name for name in ("seed", "remote.git", "program"))
        seed.mkdir()
        state = work / "state"
        env = {key: value for key, value in os.environ.items() if not key.startswith("LODE_")}
        env["LODE_WORKDIR"] = str(state)

        def run(*command, cwd=work, task=None):
            result = subprocess.run(command, cwd=cwd, env=env, input=task, text=True,
                                    capture_output=True, timeout=180)
            if result.returncode != 0:
                raise RuntimeError(f"{command[0]} failed\n{result.stdout}{result.stderr}")
            return result.stdout.strip()

        (seed / ".gitignore").write_text(".lake/\n")
        (seed / "lean-toolchain").write_text((ROOT / "lean-toolchain").read_text())
        (seed / "intent.txt").write_text(INTENT)
        (seed / "constraints.txt").write_text(CONSTRAINTS)
        (seed / "lakefile.toml").write_text(f'''name = "addition-example"
defaultTargets = ["cell-addition"]

[[require]]
name = "linen"
path = {json.dumps(str(linen), ensure_ascii=False)}

[[lean_lib]]
name = "Cell"
libName = "Cell"
roots = ["Cell.Contract", "Cell.Addition"]

[[lean_exe]]
name = "cell-addition"
root = "Main"
''')
        run("git", "init", "-q", "-b", "main", cwd=seed)
        run("git", "add", ".", cwd=seed)
        run("git", "-c", "user.name=Cell fixture", "-c", "user.email=fixture@lode",
            "-c", "commit.gpgsign=false", "commit", "-qm", "Seed addition project", cwd=seed)
        run("git", "clone", "-q", "--bare", seed, remote)

        files = {"Cell/Contract.lean": CONTRACT, "Cell/Addition.lean": IMPLEMENTATION, "Main.lean": PROGRAM}
        writes = [{"name": "write", "arguments": {"path": path, "content": text}}
                  for path, text in files.items()]
        script = [{"calls": writes + [{"name": "check", "arguments": {}}]},
                  {"calls": [{"name": "publish", "arguments": {"message": "Implement and use an addition cell"}}]},
                  {"text": "Published the addition cell and its consumer."}]
        request = work / "session.json"
        request.write_text(json.dumps({"source": {"url": remote.as_uri(), "branch": "main"},
                                       "tools": ["write", "check", "publish"],
                                       "model": {"api": "scripted", "script": script}}))
        run(binary, "run", "--config", request, task=INTENT + CONSTRAINTS)

        log = next((state / "sessions").glob("*/log.jsonl"))
        entries = [json.loads(line) for line in log.read_text().splitlines()]
        results = [result for entry in entries if entry["type"] == "tool_results" for result in entry["results"]]
        assert [result["name"] for result in results] == ["write", "write", "write", "check", "publish"], results
        assert all(not result["isError"] for result in results), results

        run("git", "clone", "-q", "--branch", "main", remote, project)
        run("lake", "build", "--wfail", "Cell:static", "cell-addition", cwd=project)
        artifact = project / ".lake/build/lib/libCell.a"
        identity = work / "identity.json"
        identity.write_text(json.dumps({
            "intentSha256": hashlib.sha256((project / "intent.txt").read_bytes()).hexdigest(),
            "constraintsSha256": hashlib.sha256((project / "constraints.txt").read_bytes()).hexdigest(),
            "contractSha256": hashlib.sha256((project / "Cell/Contract.lean").read_bytes()).hexdigest(),
            "source": {"repository": remote.as_uri(), "commit": run("git", "rev-parse", "HEAD", cwd=project),
                       "module": "Cell.Addition", "declaration": "Cell.add"},
            "leanToolchain": (project / "lean-toolchain").read_text().strip(),
            "target": f"{platform.machine()}-{platform.system().lower()}",
            "runtimeAbi": "lean-static-library-example-v1",
        }))
        manifest = work / "manifest.json"
        manifest.write_text(run(binary, "cell", "manifest", identity, artifact) + "\n")
        run(binary, "cell", "verify", manifest, artifact)
        print(f"Verified cell manifest for {artifact.name}")
        program = project / ".lake/build/bin/cell-addition"
        for left, right, expected in [(2, 3, 5), (0, 8, 8), (123456789, 987654321, 1111111110)]:
            actual = run(program, str(left), str(right), cwd=project)
            assert actual == str(expected), (left, right, actual)
            print(f"{left} + {right} = {actual}")
        if args.output is not None:
            shutil.copytree(project, args.output, ignore=shutil.ignore_patterns(".git", ".lake"))
            artifacts = args.output / "artifacts"
            artifacts.mkdir()
            shutil.copy2(artifact, artifacts)
            shutil.copy2(manifest, artifacts)
            print(f"Generated project copied to {args.output}")


if __name__ == "__main__":
    main()
