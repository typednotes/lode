#!/usr/bin/env python3
"""Export a published project in every format (SPEC S10)."""

import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".lake/build/bin/lode"
PROGRAM = """import Lean.Data.Json
import Lean.Data.JsonRpc

open Lean

def add (input : Nat × Nat) : Nat := input.1 + input.2

def serveAddition : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  repeat
    let line ← stdin.getLine
    if line.isEmpty then break
    let req : Except String JsonRpc.Message := Json.parse line >>= fromJson?
    let .ok (.request id "call" (some (.arr #[a, b]))) := req
      | throw (IO.userError "expected an addition call")
    let input : Nat × Nat ← IO.ofExcept ((do
      return (← fromJson? a, ← fromJson? b) : Except String (Nat × Nat)).mapError IO.userError)
    stdout.putStrLn (toJson (JsonRpc.Message.response id (toJson (add input)))).compress
    stdout.flush

def main : List String → IO Unit
  | [a, b] => IO.println (add (a.toNat!, b.toNat!))
  | [] => serveAddition
  | _ => throw (IO.userError "expected two arguments")
"""


def main():
    # GnuPG's Unix socket path must fit on macOS as well as Linux.
    with tempfile.TemporaryDirectory(prefix="lode-out-", dir="/tmp") as directory:
        work = Path(directory).resolve()
        env = {key: value for key, value in os.environ.items() if not key.startswith("LODE_")}
        env["LODE_WORKDIR"] = str(work / "state")
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = os.devnull

        def run(*command, cwd=work, task=None, ok=True):
            result = subprocess.run(command, cwd=cwd, env=env, input=task,
                                    text=True, capture_output=True, timeout=100)
            assert (result.returncode == 0) == ok, (command, result.stdout, result.stderr)
            return result

        seed = work / "seed"
        project = seed / "project"
        project.mkdir(parents=True)
        (seed / "outside.txt").write_text("not in the project archive\n")
        (project / "lean-toolchain").write_text((ROOT / "lean-toolchain").read_text())
        (project / ".gitignore").write_text(".lake/\n")
        (project / "lakefile.toml").write_text(
            'name = "fixture"\ndefaultTargets = ["add"]\n[[lean_exe]]\nname = "add"\nroot = "Main"\n'
        )
        run("git", "init", "-q", "-b", "main", cwd=seed)
        run("git", "add", ".", cwd=seed)
        run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@lode",
            "commit", "-qm", "Seed project", cwd=seed)
        remote = work / "remote.git"
        run("git", "clone", "-q", "--bare", seed, remote)

        request = work / "request.json"
        request.write_text(json.dumps({
            "source": {"url": remote.as_uri(), "branch": "main", "path": "project"},
            "tools": ["write", "publish"],
            "model": {"api": "scripted", "script": [
                {"calls": [{"name": "write", "arguments": {"path": "Main.lean", "content": PROGRAM}}]},
                {"calls": [{"name": "publish", "arguments": {"message": "Publish the addition worker"}}]},
                {"text": "Published."},
            ]},
        }))
        run(BINARY, "run", "--config", request, task="Publish a program that adds two numbers.\n")
        session = next((work / "state/sessions").iterdir()).name
        export = [BINARY, "output", session]
        expected = run("git", "-C", remote, "rev-parse", "main").stdout.strip()

        receipt = json.loads(run(*export, "--format", "git").stdout)
        assert receipt == {"format": "git", "repository": remote.as_uri(), "branch": "main",
                           "commit": expected, "project": "project", "path": None, "manifestPin": None}
        source = json.loads(run(*export, "--format", "source-package").stdout)
        with tarfile.open(source["path"]) as archive:
            assert archive.extractfile("Main.lean").read().decode() == PROGRAM
            assert set(archive.getnames()) == {".gitignore", "Main.lean", "lakefile.toml", "lean-toolchain"}
        run(*export, "--format", "source-package", ok=False)

        executable = json.loads(run(*export, "--format", "executable", "--target", "add").stdout)
        worker = Path(executable["path"])
        assert run(worker, "2", "3").stdout == "5\n"
        assert run(worker, "0", "8").stdout == "8\n"
        assert "cell output requires --package" in run(*export, ok=False).stderr
        run(*export, "--format", "executable", "--target", "../bin", ok=False)
        run(*export, "--format", "executable", "--target", "unknown", ok=False)
        print("PASS: Git revision, scoped source archive, runnable executable, and default cell selection")

        verify_cell(run, env, work, export, remote, expected, worker)

        checkout = work / "state/sessions" / session / "checkout/project"
        (checkout / "unpublished.lean").write_text("-- unpublished\n")
        assert "publish pending changes" in run(*export, "--format", "git", ok=False).stderr


def verify_cell(run, env, work, export, remote, commit, worker):
    """Use Linen and a disposable key to build and verify a v2 export."""
    key_home = work / "gnupg"
    key_home.mkdir(mode=0o700)
    env["GNUPGHOME"] = str(key_home)

    def sha(text):
        return hashlib.sha256(text.encode()).hexdigest()

    try:
        run("gpg", "--batch", "--passphrase", "", "--quick-generate-key",
            "Cell Output Fixture <fixture@lode.example>", "ed25519", "sign", "1d")
        listing = run("gpg", "--batch", "--with-colons", "--list-secret-keys").stdout
        fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
        keyring = work / "public.gpg"
        with keyring.open("wb") as stream:
            subprocess.run(["gpg", "--batch", "--export", fingerprint], cwd=work, env=env,
                           stdout=stream, check=True, timeout=15)

        runtime = {
            "leanToolchain": (ROOT / "lean-toolchain").read_text().strip(),
            "target": f"{platform.machine()}-{platform.system().lower()}",
            "runtimeAbi": "addition-test-v1",
            "auditVersion": "addition-fixture-v1",
            "codecSha256": sha("two JSON naturals in, one natural out"),
        }
        metadata = {
            "revision": {
                "intentSha256": sha("add two numbers"),
                "constraintsSha256": sha("no effects in the addition"),
                "contractSha256": sha("Nat × Nat → Nat"),
                "source": {"repository": remote.as_uri(), "commit": commit, "project": "project",
                           "module": "Main", "declaration": "add"},
            },
            "inputs": {"sourceSha256": sha(PROGRAM), "wrapperSha256": sha(PROGRAM),
                       "dependenciesSha256": sha(runtime["leanToolchain"]), "linkSha256": sha("lake add:exe")},
            "runtime": runtime,
        }
        record = work / "build.json"
        record.write_text(json.dumps(metadata))
        compiled = json.loads(run(*export, "--target", "add", "--build-record", record,
                                  "--key", fingerprint).stdout)
        assert compiled["format"] == "cell"
        assert Path(compiled["path"]).parent.name == "cell"
        manifest_bytes = (Path(compiled["path"]) / "manifest.json").read_bytes()
        assert hashlib.sha256(manifest_bytes).hexdigest() == compiled["manifestPin"]
        other_metadata = work / "other-build.json"
        metadata["revision"]["source"]["commit"] = "f" * 40
        other_metadata.write_text(json.dumps(metadata))
        wrong = work / "wrong"
        assert "does not match" in run(*export, "--target", "add", "--build-record", other_metadata,
                                       "--key", fingerprint, "--output", wrong, ok=False).stderr
        assert not wrong.exists()

        package = work / "package"
        pin = json.loads(run(BINARY, "cell", "package", record, worker, package, "--key", fingerprint).stdout)["pin"]
        admission = work / "admission.json"
        admission.write_text(json.dumps({"pin": pin, "runtime": runtime, "keyring": keyring.name}))
        packaged = ["--package", package, "--admission", admission]
        received = json.loads(run(*export, *packaged, "--output", work / "verified").stdout)
        assert received["manifestPin"] == pin
        verified = Path(received["path"])
        assert json.loads((verified / "manifest.json").read_text())["version"] == 2
        call = '{"jsonrpc":"2.0","method":"call","id":7,"params":[9,4]}\n'
        # Confirm the exported worker speaks the cell call protocol.
        with tempfile.TemporaryDirectory() as stage:
            native = Path(stage) / "worker"
            native.write_bytes((verified / "worker").read_bytes())
            native.chmod(0o700)
            assert json.loads(run(native, task=call).stdout)["result"] == 13

        bad = work / "bad"
        (package / "worker").write_bytes(b"changed")
        run(*export, *packaged, "--output", bad, ok=False)
        assert not bad.exists()
        print("PASS: signed Linen v2 default cell export, worker call, and payload tamper refusal")
    finally:
        run("gpgconf", "--kill", "gpg-agent", ok=True)


if __name__ == "__main__":
    main()
