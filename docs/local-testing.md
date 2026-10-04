# Testing lode locally: CLI and curl

For a wider tour with diagrams, task recipes and Lun examples, see the
[illustrated user guide](user-guide.md).

Both interfaces run the same session engine over a **separate clone** of an
existing Git branch. Only committed source files enter that clone. `publish`
creates a commit and pushes it to the local source repository.

Use a **bare repository** for publication: Git normally refuses to push to
the checked-out branch of a non-bare repository. For your own project, create
a local bare snapshot with `git clone --bare /absolute/path/to/project /tmp/project.git`
and use that snapshot as lode's source. Inspect the result there or fetch it
back into your working repository. This does not configure a hosted remote.

## 1. Build and prepare a disposable local repository

Run from the lode checkout. You need `git`, `bash`, `curl`, `jq`, and the
Lean toolchain/native dependencies needed to build lode.

```sh
lake build lode
work="$(mktemp -d /tmp/lode-local.XXXXXX)"
mkdir -p "$work/seed"
cat > "$work/seed/lakefile.toml" <<'TOML'
name = "demo"
defaultTargets = ["Demo"]

[[lean_lib]]
name = "Demo"
TOML
cp lean-toolchain "$work/seed/lean-toolchain"
printf 'def Demo.answer : Nat := 42\n' > "$work/seed/Demo.lean"
git -C "$work/seed" init -q -b main
git -C "$work/seed" add -A
git -C "$work/seed" -c user.name=demo -c user.email=demo@lode \
  -c commit.gpgsign=false commit -q -m seed
git clone -q --bare "$work/seed" "$work/remote.git"
printf 'Test directory: %s\n' "$work"
```

The branch must exist and contain at least one commit. Local source URLs
must be absolute `file:///...` paths with plain path components (letters,
digits, `.`, `_`, `-`): spaces and percent-encoded paths are not accepted.
The `/tmp/lode-local.XXXXXX` setup above satisfies that grammar.

## 2. Make a no-key smoke-test request

The `scripted` API supplies deterministic model replies locally. This checks
the actual agent loop, file writes, Lean compilation and Git publication
without contacting a provider, liaison or lun.

```sh
jq -n --arg url "file://$work/remote.git" '{
  source: {url: $url, branch: "main"},
  tools: ["write", "check", "publish"],
  model: {
    api: "scripted",
    script: [
      {text: "Writing and checking a module.", calls: [
        {name: "write", arguments: {
          path: "Demo/Hello.lean",
          content: "def Demo.hello : String := \"hello from lode\"\n"
        }},
        {name: "check", arguments: {targets: ["Demo.Hello"]}},
        {name: "publish", arguments: {message: "Local lode smoke test"}}
      ]},
      {text: "Done: Demo.hello is published."}
    ]
  }
}' > "$work/session.json"
```

For the following scripted examples, use a shell without `LODE_MODEL_*`
defaults. The request provides its own model; no API key is needed.

## 3. Run through stdin/stdout/stderr

```sh
LODE_WORKDIR="$work/cli-state" .lake/build/bin/lode run \
  --config "$work/session.json" > "$work/answer.txt" 2> "$work/progress.log" <<'TASK'
Write Demo.hello, check it, and publish it.
TASK
cat "$work/answer.txt"
cat "$work/progress.log"
git -C "$work/remote.git" log -1 --oneline main
git -C "$work/remote.git" show main:Demo/Hello.lean
```

Stdout contains `Done: Demo.hello is published.`. Stderr names the session
and its checkout and reports `Build succeeded`, the published commit, and
`run_finished`. The process exits `0`. `run` starts no HTTP listener and
automatically enables local mode.

For a later task, take the session ID printed on stderr and run:

```sh
LODE_WORKDIR="$work/cli-state" .lake/build/bin/lode run --resume SESSION_ID <<'TASK'
Continue with the next improvement.
TASK
```

Use a real model for useful follow-up tasks: the smoke-test script above is
exhausted after its first run. CLI input is one task read through EOF;
when typing directly, end it with Ctrl-D on an empty line. It is a batch
stdio interface, not an interactive line-by-line chat or token stream.

## 4. Run the same test with curl

Prepare a fresh bare snapshot so this test has its own new change to publish:

```sh
git clone -q --bare "$work/seed" "$work/http.git"
jq --arg url "file://$work/http.git" '.source.url = $url' \
  "$work/session.json" > "$work/http-session.json"
LODE_WORKDIR="$work/http-state" LODE_ALLOW_LOCAL=1 LODE_TOKEN=dev \
  .lake/build/bin/lode serve
```

Leave that server running. In a **second terminal**, set `work` to the test
directory printed in step 1, then run:

```sh
work=/tmp/lode-local.REPLACE_ME
base=http://127.0.0.1:8080
token=dev
curl -fsS "$base/_health"

session="$(curl --fail-with-body -sS "$base/v0/sessions" \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data-binary "@$work/http-session.json")"
printf '%s\n' "$session" | jq .
id="$(printf '%s\n' "$session" | jq -er .id)"

curl --fail-with-body -sS "$base/v0/sessions/$id/messages" \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data-binary '{"text":"Write Demo.hello, check it, and publish it."}' | jq .

after=0
while :; do
  page="$(curl --fail-with-body -sS --max-time 35 \
    "$base/v0/sessions/$id/messages?after=$after&wait=30" \
    -H "Authorization: Bearer $token")" || break
  printf '%s\n' "$page" | jq '.entries[]'
  after="$(printf '%s\n' "$page" | jq -r .next)"
  [ "$(printf '%s\n' "$page" | jq -r .running)" = false ] && break
done

curl --fail-with-body -sS "$base/v0/sessions/$id" \
  -H "Authorization: Bearer $token" | jq '{state, error, workspace}'
git -C "$work/http.git" log -1 --oneline main
git -C "$work/http.git" show main:Demo/Hello.lean
```

Creation returns `201`, submitting the task returns `202`, and the log
ends with `run_finished`. Tool results should have `isError: false`, and
the final status should have `state: "idle"`, `error: null`. `running: false`
alone does not imply success: inspect the terminal event and tool results.
`/_health` has an empty response body on success.

If port 8080 is busy, set `LODE_PORT=8085` when starting the server and use
`base=http://127.0.0.1:8085` in the curl terminal. `--fail-with-body` needs
curl 7.76 or later; it retains the JSON error when HTTP status is 400 or above.

## 5. Use a real model and your own repository

Configure a direct provider on the process that runs lode:

```sh
export LODE_MODEL_API=anthropic
export LODE_MODEL_NAME=claude-sonnet-4-5
export LODE_MODEL_API_KEY="$ANTHROPIC_API_KEY"

.lake/build/bin/lode run --repo /tmp/project.git --branch main --path lean <<'TASK'
Implement the requested Lean function, check it and publish the change.
TASK
```

Choose the model ID available to your provider account. Omit `--path` for
a project at the repository root. CLI state defaults to
`$HOME/.local/state/lode`; set `LODE_WORKDIR` to choose another directory.
The operator's key is used only for its configured default model endpoint.

For an OpenAI-compatible local model server, set `LODE_MODEL_API=openai`,
`LODE_MODEL_NAME` to the loaded tool-capable model, `LODE_MODEL_BASE_URL` to
its API root (for example `http://127.0.0.1:8000/v1`, without a trailing `/`),
and `LODE_MODEL_API_KEY` to the server's key (or a non-empty placeholder if
it accepts unauthenticated requests). HTTP model endpoints require local
mode, which `run` enables automatically.

For curl, start `serve` with the same model environment plus
`LODE_ALLOW_LOCAL=1`, `LODE_WORKDIR` and `LODE_TOKEN`. Create a session with
only `source` and an explicit tool list; **omit `model`** to use the default:

```sh
curl --fail-with-body -sS "$base/v0/sessions" \
  -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
  --data-binary '{
    "source": {"url":"file:///tmp/project.git","branch":"main","path":"lean"},
    "tools": ["read","ls","grep","write","edit","todo","check","publish"]
  }' | jq .
```

Then submit and follow tasks with the curl commands in step 4. Inspect
unpublished changes with `GET /v0/sessions/{id}/diff`; the printed CLI
checkout can also be inspected with Git. Lun is needed only for
`lun_build`/`lun_call`, and must be configured separately.

Do not use the same `LODE_WORKDIR` for concurrent CLI/server processes:
sessions have in-process locking, not cross-process coordination.

## Regression commands

```sh
lake test
python3 test/cli.py
test/e2e.sh
```

The native tests cover stdin/streams, compilation/publication, session resume,
local default-model transport, tool-policy denial and failure exits. The curl
suite additionally covers steering, abort, diff, authentication and restart.
