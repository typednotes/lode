# Lode v0.5.1 — runnable examples and strict type checking

A patch release over 0.5.0: new runnable examples, clearer generation guidance
for graphs, and a stricter build. The HTTP API, CLI, session/tool contracts and
dependency pins (Linen 1.12.0, Liaison 0.6.0 SDK) are unchanged.

## Examples

- `Examples/client.py` — a standard-library-only Python HTTP client for Lode's
  API (sessions, cursors, questions, deadlines and `{status, body}` envelopes),
  covered by `test/python_client.py` in CI.
- `Examples/guide/run.py` — a scripted, no-provider-key walkthrough: it builds
  Lode and the sibling Lun, generates a complete Lean project with functions and
  a graph in a disposable Git repository, and verifies the compiled Lun results.
  See [the walkthrough](../Examples/guide/README.md).
- `Examples/interactive/run.py` — an interactive conversation (`/demo`, then
  `/lun` to call the published functions and update graph inputs; `--real-model`
  for your own tasks and revisions). See [its walkthrough](../Examples/interactive/README.md).
- `Examples/graph_svg.py` — renders a compiled Lun graph's topology and latest
  node outcomes as a self-contained SVG (`viz`/`svg` at the interactive Lun
  prompt, `--svg` in the guide), covered by `test/graph_svg.py` in CI.
- The [user guide](user-guide.md) and [LSP notes](lsp.md) describe these
  examples. The agent's instructions now say that the Lean LSP checks `.lean`
  files, not graph programs inside `lun.json`, and that `lun_build` is the check
  for the exact manifest graph; `LunDriver` is never a project dependency.

## Strict type checking

`lakefile.lean` turns `autoImplicit` and `relaxedAutoImplicit` off for the
package, and the CI lean-action build uses `--wfail`: any warning, including
`declaration uses 'sorry'`, fails the build. The binders that were auto-bound
are now explicit: section `variable`s for `root` (`Lode.Lsp`) and `ceiling`
(`Lode.ToolPolicy`), implicit binders on two `Lode.Tools` declarations, and
explicit parameters on seven test examples; no statement changed. `AGENTS.md` follows the agents-md
standard v3; the "never run `git push`" override remains.

## Verification

Locally (macOS): `lake build --wfail`, `lake build --wfail LodeTest` and
`lake test` passed with no warnings; the offline release-gate regressions
(50 cases), `test/python_client.py`, `test/graph_svg.py`, `test/lsp.py`,
`test/cli.py`, `test/e2e.sh`, `test/liaison.sh` and
`test/native.py .lake/build/bin/lode` passed. `test/lun.sh` and the guide/
interactive examples against a real Lun were not rerun for this patch; CI's
`lun` job runs `test/lun.sh`.

## Publication

The release commit and annotated `v0.5.1` tag are prepared locally; publication
is the user's action. Push main and `v0.5.1` together; the image publisher waits
for that exact commit's main CI. Existing tags remain immutable.
