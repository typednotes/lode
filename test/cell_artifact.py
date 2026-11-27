#!/usr/bin/env python3
"""Verify native cell manifests and detached signatures using a disposable keyring."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


BINARY = Path(__file__).resolve().parents[1] / ".lake/build/bin/lode"


def main():
    with tempfile.TemporaryDirectory(prefix="lode-cell-sign-") as directory:
        work = Path(directory)
        key_home = work / "gnupg"
        key_home.mkdir(mode=0o700)
        env = dict(os.environ, GNUPGHOME=str(key_home))

        def run(*command, check=True):
            result = subprocess.run(command, env=env, cwd=work, capture_output=True, timeout=25)
            if check and result.returncode:
                raise AssertionError(result.stderr.decode())
            return result

        artifact = work / "payload"
        artifact.write_bytes(b"compiled addition fixture\x00\xff")
        identity = work / "identity.json"
        metadata = {"intentSha256": "a" * 64, "constraintsSha256": "b" * 64, "contractSha256": "c" * 64,
            "source": {"repository": "https://github.com/typednotes/lode", "commit": "f" * 40,
                       "module": "Cell.Addition", "declaration": "Cell.add"},
            "leanToolchain": "leanprover/lean4:v4.36.0", "target": "x86_64-linux", "runtimeAbi": "fixture-v1"}
        identity.write_text(json.dumps(metadata))
        manifest = work / "manifest.json"
        manifest.write_bytes(run(BINARY, "cell", "manifest", identity, artifact).stdout)
        verified = json.loads(manifest.read_text())
        assert verified["artifactSha256"] == hashlib.sha256(artifact.read_bytes()).hexdigest()
        assert verified["artifactBytes"] == artifact.stat().st_size
        run(BINARY, "cell", "verify", manifest, artifact)
        metadata["source"]["commit"] = "main"
        identity.write_text(json.dumps(metadata))
        assert run(BINARY, "cell", "manifest", identity, artifact, check=False).returncode != 0

        try:
            run("gpg", "--batch", "--passphrase", "", "--quick-generate-key",
                "Lode signing fixture <cell@lode.example>", "ed25519", "sign", "1d")
            listing = run("gpg", "--batch", "--with-colons", "--list-secret-keys").stdout.decode()
            fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
            keyring = work / "compiler.gpg"
            keyring.write_bytes(run("gpg", "--batch", "--export", fingerprint).stdout)
            signature = work / "manifest.asc"
            signature.write_bytes(run(BINARY, "cell", "sign", manifest, artifact, "--key", fingerprint).stdout)
            run(BINARY, "cell", "verify", manifest, artifact, "--signature", signature, "--keyring", keyring)

            altered = work / "altered.json"
            verified["identity"]["runtimeAbi"] = "different-v1"
            altered.write_text(json.dumps(verified))
            assert run(BINARY, "cell", "verify", altered, artifact, "--signature", signature,
                       "--keyring", keyring, check=False).returncode != 0
            original = artifact.read_bytes()
            artifact.write_bytes(b"C" + original[1:])
            assert run(BINARY, "cell", "verify", manifest, artifact, check=False).returncode != 0
            assert run(BINARY, "cell", "sign", manifest, artifact, "--key", fingerprint, check=False).returncode != 0
            print("PASS: cell provenance, SHA-256, signed ABI metadata and tamper refusal")
        finally:
            run("gpgconf", "--kill", "gpg-agent", check=False)


if __name__ == "__main__":
    main()
