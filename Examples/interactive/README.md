# Interactive Lode and Lun

From the Lode repository root:

```sh
uv run Examples/interactive/run.py
```

The script builds Lode and the coordinated sibling `../lun`, starts local HTTP
services, and creates a disposable bare Git repository with an existing `main`
branch. Like the [generation guide](../guide/README.md), it requires Python
3.10+, uv, Git, Lean/Lake and the services' native build dependencies. uv installs
Rich for readable replies. Use Lun 0.4.1+ and the coordinated Linen dependency
(the default is Lode's locked `.lake/packages/linen`).

## Try it without a model key

At the `lode>` prompt, type `/demo`. Lode asks whether to build the example;
enter `1` at `answer>`. The scripted model then writes a complete Lean project,
checks it with Lake and LSP, publishes it, repairs a deliberate graph error,
and builds and calls it through Lun. These are real tool executions, compilation
and runtime calls. The scripted model follows fixed turns and does not interpret
arbitrary tasks.

Once Lode finishes, enter `/lun` to test the published result yourself:

```text
lode> /demo
answer> 1
lode> /lun
lun> viz basket
lun> function double 21
lun> function add [7,8]
lun> function seed
lun> graph basket {"value":5}
lun> graph basket {"value":8}
lun> graph basket {"value":8}
lun> show basket
lun> reset basket
lun> graph basket {"value":5}
lun> back
lode> /status
lode> /quit
```

The function outputs are `42`, `15` and `10`. `basket` computes twice `value`
plus `10`: first `20`, then `26`. Updating `value` preserves the graph's state;
only `value`, `double` and `add` change. Repeating `8` returns an empty `changed`
array. `reset basket` discards the continuation, so the next call initializes
the graph again, including the constant `seed`.

Input is ordinary JSON, without shell quoting. Multi-argument functions receive
a JSON array; a Unit function can omit its input. Malformed JSON and HTTP refusals
leave the saved graph state unchanged. Graph node errors are returned as outcomes
alongside state: look for `error` and downstream `skipped` fields, then update the
inputs to recover. Neither case leaves the prompt. Function and graph calls use
a local actor binding and an explicit empty effects/domain policy, so this
example is for pure functions and producers.

## Visualize the graph in your browser

At `lun>`, enter `viz basket` to save an SVG and open it in your default browser.
This works before the graph has run: the view comes from **Lun's compiled
topology**, including its input nodes, function applications, sources and sinks.
Arrow labels are the receiving function's argument positions, starting at `1`.
Function signatures and producer markers come from the compiled build metadata.

After a graph call, the view also shows its latest outputs, errors and skipped
dependencies. Changed nodes have a teal border; errors are red and skipped nodes
amber. Long labels and JSON values wrap and shorten inside the cards; hover for
their full text. The SVG uses plain XML and system fonts, with no extra package,
Graphviz installation, network assets or embedded scripts.

```text
lun> svg basket
lun> graph basket {"value":5}
lun> viz basket
lun> graph basket {"value":8}
```

`svg basket` saves without opening a browser. Omitting the name (`svg` or `viz`)
exports all compiled graphs. Every command prints a `file://` URI you can open
manually. Once a graph is exported, its file is regenerated after each `graph`,
`next` or `reset` command. **Refresh the browser to see the update**, or use `viz`
again. The browser displays a static snapshot of the latest saved SVG.

Files are scoped by build ID under the demo's `graphs/` directory. Use `--keep`
to retain the demo, or select a persistent output directory:

```sh
uv run Examples/interactive/run.py --svg-dir ./graph-svg
uv run Examples/interactive/run.py --no-browser --svg-dir ./graph-svg
```

`--no-browser` makes `viz` behave like a save-only command. `--demo` also disables
browser launching while verifying SVG export through the real prompt. Browser
launch failures leave the SVG available at the printed URI.

## Chat with a real model, then test its changes

Configure `LODE_MODEL_*` as in [Choose a real model](../../docs/user-guide.md#3-choose-a-real-model), then run:

```sh
uv run Examples/interactive/run.py --real-model --keep
```

At `lode>`, enter your task as a line of text. For example:

```text
Create Demo.square : Nat → Eff [] Nat, declare it as square in lun.json, and a squares graph with Nat input n feeding square.
```

The client adds the local Linen path, Lean toolchain and a request to check,
publish and build through Lun. Lode can ask necessary questions; choose a number
or type an answer when free text is allowed. Then try:

```text
lode> /lun
lun> function square 12
lun> graph squares {"n":7}
lun> back
lode> Make square return n*n+1; keep the signature and graph, then check, publish and rebuild.
lode> /lun
lun> function square 12
lun> graph squares {"n":7}
lun> back
```

Each `/lun` selects the session's latest ready build and checks that its source
commit matches the session's published head. A missing, failed or stale build
prompts you to ask Lode to repair/publish/rebuild. Unpublished edits are reported;
Lun executes the published commit. Graph state is retained by **build ID and graph
name**, so a new build starts with fresh state. Real-model runs consume provider
usage and depend on the model completing the task.

## Commands and lifecycle

At `lode>`, `/help` lists commands. `/status` displays checkout/run status,
questions and the build ID. `/diff` shows unpublished changes. `/follow` resumes
log following from the saved entry cursor and handles a pending question.
`/abort` cancels work or invalidates a pending question. Ctrl-C while following
requests cancellation; use `/follow` to wait for completion. During an in-flight
model call, cancellation takes effect after the call returns or times out.

At `lun>`, `help` lists commands. `show` displays the compiled build's function
signatures and graph topology; `show NAME` displays a saved graph reply.
`next NAME` resumes a pure producer graph at its returned `nextCallAt`, preserving
its continuation. Each graph has an explicit demo clock initially set to
`1000` ms; `next` advances it immediately rather than sleeping. A graph without
pending work reports that fact. The client owns this state and clock; Lun does
not store graph sessions. `back` returns to the same Lode conversation.

Session creation uses `background:true`: the session is saved and returned
before repository preparation finishes. A task submitted during checkout is
queued until the checkout is ready, and the client follows that transition.

`/quit` at `lode>` or EOF at any prompt stops both services. State, repositories
and logs are removed on exit unless `--keep` is selected. Retention keeps files,
not running services; graph continuations in this example are in memory only.
The script prints the scratch directory and service URLs at startup.

```sh
# Reuse already-built executables, or select coordinated source checkouts.
uv run Examples/interactive/run.py --skip-build
uv run Examples/interactive/run.py --lun ../lun --linen ../linen

# Repeatable end-to-end verification through the same interactive prompts.
uv run Examples/interactive/run.py --demo --skip-build
```

`--demo` supplies keyboard input and checks the real question/answer flow, ready
published build, function outputs, stateful graph updates, unchanged-input
behavior, recovery after invalid JSON/runtime input, state reset and SVG export.
It exits with `Interactive demo passed` on success and a nonzero exit code on
failure.

Without uv, install `rich>=13` and run the script with Python. Setup and prompts
go to stderr; readable agent progress and JSON replies go to stdout.
