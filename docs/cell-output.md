# Linen cell output

A compiler with access to the signing key can build and package a worker
from a published session. The target must implement Linen's positional
JSON-RPC call protocol. Run this in the trusted compiler environment.

```sh
lode output "$SESSION" --target add-worker --build-record build.json --key "$FINGERPRINT"
```

To package and admit an independently checked worker, use the two steps below.

```sh
lode cell package build.json worker output/compiler-cell --key "$FINGERPRINT"
lode output "$SESSION" --package output/compiler-cell --admission admission.json
```

`build.json` has the following members.

| Member | Contents |
| --- | --- |
| `revision` | `intentSha256`, `constraintsSha256`, `contractSha256`, and `source` with `repository`, `commit`, `project`, `module`, and `declaration` |
| `inputs` | `sourceSha256`, `wrapperSha256`, `dependenciesSha256`, and `linkSha256` for the actual compiler inputs |
| `runtime` | `leanToolchain`, `target`, `runtimeAbi`, `auditVersion`, and `codecSha256` |

Pass the exact source coordinates and SHA-256 digests. The compiler verifies
the correspondence between those inputs and the executable before selecting
its signing key. The package commands emit `worker`, `manifest.asc` and
`manifest.json`, and returns the package path and manifest pin as JSON.

`admission.json` supplies the consumer's expected `pin`, independent
`runtime`, and `keyring` path. Relative keyring paths are resolved against
the admission file's parent. The exported package can be opened by Linen's
`System.Cell.openPackage` and called through its worker interfaces. Preserve
the manifest bytes exactly, including whitespace.

Exercise all four Lode outputs, including signing and verifying a disposable
addition worker.

```sh
python3 test/output.py
```
