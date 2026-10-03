# Lean language-server tool

`lsp` is one finite writer operation. The organization/session allowlist and
the selected agent must both contain `lsp`; the actual Tools dispatcher consumes
`AuthorizedArgs` before filesystem access or a subprocess. Existing bounded
policy narrowing and launch-ceiling proofs apply to it. The Typednotes
`WRITER_TOOLS` catalog and default policy include the same operation.

## Arguments and results

```json
{"operation":"hover","path":"Demo/Math.lean","line":12,"character":8}
```

- `hover`, `definition`, `completion`, and `goals` require `line` and `character`.
- `diagnostics` accepts only `operation` and `path`.
- Lines and characters are **zero-based**. Characters count **UTF-16 code units**,
  matching Lean 4.34's LSP, not UTF-8 bytes or Unicode scalar values. A non-BMP
  character occupies two units; a cursor between its surrogate units is refused.
  Positions beyond a line or the document are refused, not silently clamped.
- `path` is relative to the session's project directory. Absolute paths,
  traversal/dot components, backslashes, URI escapes, controls, `.git`, `.lake`,
  non-`.lean` names, directories, FIFOs and invalid UTF-8 are refused. Files must
  exist. Canonical project/file paths are confined component-wise to the canonical
  checkout; symbolic links outside it fail before spawning Lake.
- Unknown fields are refused. There is no `uri`, `method`, `params`, unsaved
  `text`, RPC connection, command, resolve, code-action or edit input.

The output is bounded JSON with `operation`, `path`, `positionEncoding:"utf-16"`
and a data-only `result`. Definitions return checkout-relative `locations`
and an `omitted` count, never source contents. External/toolchain definitions,
outside symlinks, malformed file URIs and bookkeeping paths are omitted.
Hover/goals/diagnostic text containing file URIs or absolute path tokens is
suppressed. Diagnostic related information/data and completion commands,
documentation/data/edits are omitted. Completions preserve exact-prefix matches
first and return at most 100 labels/details/kinds, with `truncated` metadata.
Oversized final results fail with a bounded error rather than invalid cut JSON.

## Worker and budgets

Each call snapshots one disk document, starts exactly `lake serve` in the
canonical project directory, initializes JSON-RPC 2.0, opens the snapshot at
version 1 and waits for `textDocument/waitForDiagnostics`. Lean 4.34's reporter
and command snapshots are complete before this barrier replies. Only the opened
URI's version-1 diagnostics are accumulated; incremental batches append and
ordinary batches replace. Other document versions/URIs are ignored.

The four position queries use the fixed methods `textDocument/hover`,
`textDocument/definition`, `textDocument/completion`, and `$/lean/plainGoal`.
`dependencyBuildMode:"never"` avoids requesting automatic dependency builds;
existing imports must already be built. The fixed watcher registration and
parameterless inlay-hint/semantic-token refresh requests Lean sends are discarded,
as in Lean's test IPC client. Other server-initiated requests fail closed and
never dispatch effects.

- Document snapshot: at most 1,048,576 bytes.
- Response frame: at most 262,144 bytes; header: at most 1,024 bytes.
- Incoming wire traffic: at most 1,048,576 bytes and 256 messages, counting
  discarded notifications. Reading reserves space for a maximum-size frame,
  so a call may stop below the total budget.
- JSON nesting: at most 64; unquoted numeric tokens: at most 20 characters.
  Scientific exponents are refused before decoding to prevent huge integer
  expansion in Lean's JSON parser.
- Arguments: at most 4,096 bytes. Result: at most 50,000 UTF-8 bytes.
- Deadline: `min(Tools.Env.checkTimeoutMs, 30_000)` milliseconds; session abort
  is polled every 10 ms. Partial frames and blocked writes share this deadline.

Stdout is parsed with bounded Content-Length framing. Stderr is discarded,
not captured without a limit. Success, failure, timeout and abort all kill and
reap the complete process group and join the reader. The worker inherits
`Process.toolEnv`, stripping Lode's service credentials. No bash fallback exists;
the existing Linen process-group signal helper is only used for cleanup.

## Proofs and trusted boundary

Private constructors for `DocumentPath`, `WorkspaceDocument`, `Request` and
`WorkspaceLocation` carry lexical path validity, canonical component containment,
bounded snapshot size, valid UTF-16 cursor positions and operation/position shape.
Execution and definition serialization consume these witnesses. Kernel theorems
cover their invariants, the finite read-only method set and inherited
`AuthorizedArgs` launch-ceiling bounds; tests additionally exercise the OS/protocol
correspondence.

This is a read-only **tool protocol**, not a sandbox for Lean elaboration:
the project's lakefile and Lean code can execute IO, just as with `lake build`.
The existing per-trust-domain container remains the isolation boundary. OS
realpath, metadata/open, process groups and Lean's LSP implementation are trusted;
concurrent hostile filesystem mutation between checks and opens is not proved
race-free. There is no persistent worker/cache, no automatic code execution from
returned actions, and no general RPC escape hatch.

## Verification

Graph checks now include a parent/child type mismatch, a coherent unpinned parent
output change and refusal of a conflicting fixed annotation. The prompt directs
the agent to run diagnostics on a Lean file containing its graph wiring and to
use hover for argument/output types. [Caller build contracts](build-contracts.md)
keep user pins authoritative through actual Lun compilation, not merely LSP advice.

```sh
lake build +LodeTest.Lode.LspTest
python3 test/lsp.py
```

`LspTest` runs pure denial checks and kernel witnesses. `test/lsp.py` drives the
actual `Tools.execute` path against the installed Lean 4.34 server for diagnostics,
hover, completion, definition, goals and non-BMP positions. It also verifies
no-subprocess denials, path/URI confinement, stripped credentials, hostile framing,
JSON/byte/message limits, deadlines/abort and descendant cleanup using a PATH-only
pipe fixture. Success requires the real server tests; the fixture alone cannot
pass the suite. For a coordinated source workspace, `--lean-path` accepts the
already-built module search path without modifying package pins or manifests.

Both build and plan agents advertise `lsp` within the current session allowlist;
the system prompt describes its zero-based UTF-16 positions. No Session Env or
app server bridge callback is required: Tools uses its existing root, project,
abort and check-timeout fields directly.
