# A Python client that generates a Lean project for Lun

From the Lode repository root:

```sh
uv run Examples/guide/run.py
uv run Examples/guide/run.py --quiet
```

Like Lun's cookbook, this is a Rich-formatted Python script with inline `uv`
dependency metadata. It builds Lode and the sibling `../lun`, starts both local
HTTP services, creates a disposable bare Git repository, follows the agent log,
and verifies real compiled results. It needs Python 3.10+, uv, Git, Lean/Lake
and the services' native build dependencies. The coordinated Lun checkout must
support stateless graph steps (Lun 0.4.1+); the default project dependency is
Lode's locked `.lake/packages/linen`.

```sh
# Select coordinated source checkouts explicitly.
uv run Examples/guide/run.py --lun ../lun --linen ../linen

# Reuse binaries that were already built.
uv run Examples/guide/run.py --skip-build --quiet

# Keep the generated repository, checkouts, logs and compiled runtime builds.
uv run Examples/guide/run.py --keep
```

Without uv, install Rich in your Python environment (`python3 -m pip install
'rich>=13'`) and run `python3 Examples/guide/run.py`. The reusable
[`Examples/client.py`](../client.py) itself has **no third-party dependencies**.

## What is scripted, and what is real?

The default model is a sequence of assistant turns with typed tool calls.
It does not interpret the task or contact a model provider. The calls go through
Lode's actual permission checks and tool dispatcher. Git publication, Lake
compilation, Lean LSP, Lun driver compilation and execution are real.

The starting repository has only `README.md` and `.gitignore`. Lode writes the
Lake configuration, toolchain, Lean modules, dependency lock and `lun.json`.
The local Linen path dependency avoids downloading/building a second copy;
the generated project needs that path to remain available. For a portable
project, use a pinned Git requirement and publish its resolved manifest.

## Follow the script

1. **Seed and connect.** `seed_repository` makes an already-committed branch in
   a bare repository. `LocalServer` starts Lun first, then Lode with
   `LODE_LUN_URL`/`LODE_LUN_TOKEN`. Ports and state directories are disposable.
2. **Create a session.** `Client.create` sends the source, explicit tool policy
   and independent caller-owned output/input/wiring contracts. Creation is
   separate from sending the task. Brokered apps additionally bind their
   projections between these two calls.
3. **Generate the project.** `script` writes [`Demo.lean`](project/Demo.lean)
   (`double`, `add`, `seed`), [`Demo/Wiring.lean`](project/Demo/Wiring.lean)
   (a payload-type check), the Lake files and [`lun.json`](lun.json). `bash`
   runs `lake update` to produce the dependency lock.
4. **Check source types.** `check` builds both modules. `lsp` asks Lean for
   diagnostics on the payload composition and hover on `double`. LSP positions
   are zero-based UTF-16 positions; they refer to these fixed fixture files.
5. **Exercise a graph diagnostic.** The first publication deliberately has
   `add doubled "oops"` in its graph. Source checks still pass, because LSP
   does not parse JSON strings. `lun_build` rejects the actual graph with a
   diagnostic attributed to `[graph basket]`.
6. **Repair and rebuild.** The script writes the correct `add doubled base`
   program, checks, publishes and builds again. Lun builds the new **published
   commit**, not Lode's uncommitted checkout.
7. **Try the result from the agent.** Input-only `lun_call` verifies
   `double(21) = 42`, `add(7,8) = 15`, `seed() = 10`, and `basket(value=5) = 20`.
8. **Inspect and call from Python.** The client verifies the terminal event,
   expected tool error, clean checks, published files, empty diff and ready
   build's commit. Direct Lun requests then initialize `basket`, save its JSON
   state, change `value` to `8` (result `26`), and repeat the unchanged input
   (empty `changed`). The constant `seed` is not recomputed by this input update.

The default run ends with **31 checks passed**, a commit SHA and a Lun build id.
`--quiet` suppresses formatted log/request/reply JSON, while setup progress still
appears on stderr. Service processes are stopped on exit. Scratch files are
removed unless `--keep` is selected; after cleanup the printed build id no
longer identifies a retained local service build. Use `--keep` for inspection.

## Try a real model

Configure `LODE_MODEL_*` as in the [user guide](../../docs/user-guide.md#3-choose-a-real-model), then:

```sh
uv run Examples/guide/run.py --real-model --keep
```

This omits the scripted model and asks the configured model to implement the
same project and graph. It keeps the caller-owned contracts and verifies the
published artifacts and direct runtime results. Repaired intermediate tool
failures are allowed; final success must still be demonstrated. A real-model
run consumes provider usage and may fail if it does not finish the task within
the configured bounds. No live-provider quality claim follows from the default
scripted run.

## Reuse the HTTP client

`Client(base_url, token)` attaches to a service you run yourself. It exposes
`create`, `sessions`, `status`, `send`, `messages`, `follow`, `diff`, `answer`,
`abort`, `credentials`, and `delete`. Use `request` for raw REST calls; it
returns `{status, body}` for JSON, text and empty responses. Higher-level helpers
raise `ApiError` on HTTP refusals, retaining `status` and `body`.

`follow` yields log entries using `next` as the cursor, follows background
checkout, and stops for idle/failure or a pending user question. It does not
equate an idle session with a successful run. Its deadline stops the client
wait, not the remote run. Save `entry['index'] + 1` to resume following, inspect
status/tool outcomes, and explicitly call `abort` when cancellation is needed.
The client does not automatically retry requests or mint credentials.

Lode's native CLI remains a one-task stdin/stdout/stderr interface. It is not
Lun's JSON-lines request protocol; this client uses Lode's HTTP API for session
operations and long polling. See [the Python cookbook](../../docs/user-guide.md#the-python-cookbook)
for reusable snippets and user-question handling.
