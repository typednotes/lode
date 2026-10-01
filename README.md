<p align="center">
  <img src="logo.svg" alt="lode" width="180">
</p>

<h1 align="center">lode</h1>

<p align="center">
  <em>A coding agent in Lean 4 that writes typed functions and reactive graphs for lun, in a repository it shares with you.</em>
</p>

<p align="center">
  <a href="https://github.com/typednotes/lode/actions/workflows/lean_action_ci.yml"><img src="https://github.com/typednotes/lode/actions/workflows/lean_action_ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/typednotes/lode/actions/workflows/docker-publish.yml"><img src="https://github.com/typednotes/lode/actions/workflows/docker-publish.yml/badge.svg" alt="Docker publish"></a>
  <a href="https://github.com/typednotes/lode/pkgs/container/lode"><img src="https://img.shields.io/badge/ghcr.io-typednotes%2Flode-blue?logo=docker" alt="Docker image"></a>
  <a href="https://github.com/typednotes/lode/tags"><img src="https://img.shields.io/github/v/tag/typednotes/lode?label=version&sort=semver" alt="Version"></a>
  <a href="https://lean-lang.org/"><img src="https://img.shields.io/badge/Lean-v4.34.0-blue" alt="Lean v4.34.0"></a>
   <a href="https://github.com/typednotes/linen"><img src="https://img.shields.io/badge/built%20on-linen%20v1.10.0-c9b896" alt="Built on linen v1.10.0"></a>
   <a href="https://github.com/typednotes/liaison"><img src="https://img.shields.io/badge/speaks-liaison%20v0.6.0-0e6b6f" alt="Speaks liaison v0.6.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0"></a>
</p>

---

`lode` is the coding agent of [typednotes](https://github.com/typednotes/typednotes):
an HTTP service that runs model-driven sessions over a branch of a git
repository and writes the Lean 4 projects [`lun`](https://github.com/typednotes/lun)
builds and serves — modules implementing **functions** (each under a declared
signature ending in linen's `Eff`), **graphs** wiring them, and the `lun.json`
declaring both. A session is done when lun builds the published commit and the
functions and graphs answer as intended.

This documentation describes the coordinated **Lode 0.4.0 / Lun 0.3.0 /
Typednotes 0.7.0 / Linen 1.10.0 / Liaison 0.6.0** release. Package locks and
runtime/image defaults use this set; local release tags still require publication.

lode holds no third-party credential: it reaches the repository (GitHub,
GitLab) and supported generative models using Messages, Chat Completions,
Responses, Gemini or Radius Pi/SSE through [`liaison`](https://github.com/typednotes/liaison), with
warrants the typednotes app mints for each connection, in liaison's own wire
format (`Liaison.Wire`). It is built on
[`linen`](https://github.com/typednotes/linen) and runs as a container.

```
 user / typednotes app ──HTTP──▶ lode ──(warrant)──▶ liaison ──▶ GitHub / GitLab              open, publish
                                  │    ──(warrant)──▶ liaison ──▶ Anthropic / Mistral / OpenAI…  the model
                                  └──────────────────▶ lun  build the published commit, call functions and graphs
```

## Table of contents

- [Features](#features)
- [Quick start](#quick-start)
- [How a session goes](#how-a-session-goes)
- [Tools](#tools)
- [HTTP API](#http-api)
- [Configuration](#configuration)
- [Docker](#docker)
- [Design](#design)
- [Project status](#project-status)
- [License](#license)

## Features

- **Expanded provider routing** — Messages, Chat Completions, Responses, Gemini
  and Radius's Pi/SSE protocol. The app's provider catalog selects the native API
  for gateways; classifier-only TypeSafe and OpenCode models cannot drive a writer.

- **Enforced writer permissions** — a launch `tools` allowlist is intersected
  with the selected agent for both advertising and execution; later updates
  may only narrow it. Execution consumes Lean permission witnesses. See
  [native writer integration](docs/native-writer.md) for the app/broker contract,
  proofs, verification and trusted boundaries. The app forwards organization
  tool settings at launch and applies monotonic narrowing to live sessions.

- **Writes for lun** — the system prompt carries lun's contract (functions,
  the allowed effects, graphs, `lun.json`), and the tools close the loop: `check`
  (`lake build` diagnostics), `publish`, `lun_build` (lun's diagnostics,
  attributed to each function and graph), `lun_call`.
- **A shared repository** — one branch of a GitHub or GitLab repository,
  opened through immutable native branch/tree/file views and published through
  a subtree-scoped commit plan. The broker enforces exact-head atomic publication
  on both hosts: GitHub `updateRefs` CAS and GitLab generated receive-pack CAS.
  Write authority does not grant deletion; stale heads and rewinds are refused.
- **Native model protocols** — five wire formats behind one conversation model,
  with stateless reasoning/signature replay, truthful session context and bounded
  local function tools. Calls are brokered and metered per declared call cost;
  explicit direct transport remains a development option.
- **Steerable** — a message sent while the agent works reaches it between two
  steps; runs can be aborted, followed by long-polling, and resumed after a
  restart.
- **Bounded** — the loop is total (structural in its fuel: at most
  `LODE_MAX_STEPS` model calls per run); tool arguments are parsed into typed
  values before anything runs; named file-tool paths are scoped to the checkout
  (linen's `FileSystem` capability, symbolic links resolved); lode's own secrets are
  scrubbed from what the model runs.
- **Long sessions** — compaction by summary when the context fills up; an
  append-only log keeps everything.
- **Two agents** — `build` does everything; `plan` reads, checks and proposes.

## Quick start

### Build

```sh
lake build
```

### Test

```sh
lake test          # unit tests (#guard): every parser and pure rule
test/e2e.sh                   # a real agent loop (scripted model) over a real repository
test/liaison.sh               # GitHub, GitLab and the model through a mock liaison
python3 test/native.py .lake/build/bin/lode  # native APIs and writer policy, no paid model
test/lun.sh ../lun ../linen   # with the coordinated Lun/Linen source checkouts
```

### Run

```sh
LODE_WORKDIR=/tmp/lode LODE_TOKEN=... \
  LODE_LIAISON_URL=http://localhost:8081 \
  LODE_LUN_URL=http://localhost:8082 LODE_LUN_TOKEN=... \
  lake exe lode
```

Needs `git`, `bash`, `elan`/`lake` and linen's native build
dependencies on the `PATH` (see the `Dockerfile`).

Then open a session and give it a task:

```sh
curl -s -X POST localhost:8080/v0/sessions -H "Authorization: Bearer $LODE_TOKEN" -d '{
  "source": {"url": "https://github.com/acme/sheets", "branch": "main", "path": "lean",
             "credentials": {"warrant": {…}, "account": "{user_id}/{connection_id}",
               "operations": [{"operation": "repositories.write", "warrant": {…}}]}},
  "model": {"name": "claude-sonnet-4-5", "credentials": {"warrant": {…}, "account": "…", "cost": 10}},
  "tools": ["read", "ls", "grep", "write", "edit", "check", "publish", "lun_build", "lun_call"]
}'
# The app's trusted minting service binds conversation/publication projections
# to the returned $ID before starting native generation.
curl -s -X POST "localhost:8080/v0/sessions/$ID/messages" \
  -H "Authorization: Bearer $LODE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"text":"Write a function that converts EUR to USD, and a graph summing two converted amounts."}'
curl -s "localhost:8080/v0/sessions/$ID/messages?after=0&wait=30" -H "Authorization: Bearer $LODE_TOKEN"
```

## How a session goes

```
POST /v0/sessions                  open a branch of a repository
POST …/messages {"text"}           a run: model → tools → model … until it answers without tool calls
                                   (a message during a run steers it)
GET  …/messages?after=n&wait=30    follow the log
GET  …/diff                        what is not published yet
POST …/abort                       stop
```

In a run, the model typically explores the repository; writes modules;
`check`s until `lake build` is clean; writes `lun.json`; `publish`es one
commit on the shared branch; `lun_build`s the published commit and fixes what
lun reports per function and graph; `lun_call`s the result; and ends with a summary
naming the commit, the lun build and the services.

## Tools

| Tool | |
|---|---|
| `read` | a text file with line numbers (≤ 2000 lines per call, `offset`/`limit`) |
| `ls` | files under a directory, git-aware (no `.git`, `.lake`, ignored files) |
| `grep` | `git grep -n -E` over tracked and untracked files |
| `write` | create or overwrite a file |
| `edit` | replace exact text, which must occur once (or `all`) |
| `bash` | a non-interactive command in the project directory (timeout ≤ 1800 s; last 2000 lines / 50 kB) |
| `todo` | the model's task list (visible in the session's status) |
| `check` | `lake build` (optionally of some targets): its errors and warnings |
| `publish` | publish project changes through a broker-owned, scope-checked atomic commit plan; removals need independent deletion grants |
| `lun_build` | have lun build the published commit with `lun.json`; wait; report state, diagnostics, functions, graphs |
| `lun_call` | call a function, or run a graph once, of the latest ready build |

The model's `lun_call` body is input-only. The authenticated app can attach a
[bounded Eff execution context](docs/runtime-bridge.md) at session launch, with
actor/graph bindings and fresh operation grants. Trials then use the same compiled
DB/vault/HTTP/files/connector interpreters as the app. Refreshes only narrow;
public ceilings survive restart, operation warrants do not.

Named file-tool paths are confined to the checkout; `.git` and `.lake` cannot be
written through them. Allowed `bash`/Lake execution still relies on container
isolation. The
`plan` agent has `read`, `ls`, `grep`, `todo`, `check` and `lun_call`.

### `lun.json`

In the project directory, written and published by the model with the code:

```json
{
  "open": ["MyProject"],
  "functions": [{"name": "double", "module": "MyProject.Math", "function": "MyProject.double",
             "signature": "Nat → Eff [] Nat"}],
  "graphs": [{"name": "main", "program": "do\n  let x ← input \"x\" Nat\n  double x"}]
}
```

lode adds the source (repository, branch, published commit, project path,
and the repository warrant) and submits it to lun. The same file lets anyone
rebuild the project from the repository alone.

## HTTP API

| Route | |
|---|---|
| `GET /_health` | `200` (empty body) |
| `POST /v0/sessions` | create a session (below): opens the workspace; `201` with its status; starts a run if `message` is given |
| `GET /v0/sessions` | every session's status, newest first |
| `GET /v0/sessions/{id}` | status: `state` (`idle`/`running`), `steps`, `queued`, `workspace.remoteHead`, `lastBuild`, `todos`, `usage`, `credentials` (which are held), `error` |
| `DELETE /v0/sessions/{id}` | delete an idle session and its workspace |
| `POST /v0/sessions/{id}/messages` | `{"text", "credentials"?, "agent"?, "tools"?}` → `202 {"queued", "session"}`; tools may only narrow |
| `GET /v0/sessions/{id}/messages?after=n&wait=s` | `{"entries": [...], "next", "running"}`: the log from entry `n`; `wait` (≤ 60 s) holds the request until something new happens |
| `POST /v0/sessions/{id}/abort` | `202`, or `409` if no run is going |
| `PUT /v0/sessions/{id}/credentials` | `{"repo"?, "model"?, "lun"?}`: fresh warrants |
| `GET /v0/sessions/{id}/diff` | unpublished changes, `text/plain` |

With `LODE_TOKEN` set, every route but `/_health` needs
`Authorization: Bearer {token}`. Errors are `{"error": "…"}`.

### Creating a session

```jsonc
{
  "source": {
    "url": "https://github.com/owner/repo",   // github.com, gitlab.com, or any https host (public, read-only)
    "branch": "main",                          // must exist; lode commits on it
    "path": "lean",                            // optional: the project directory
    "credentials": { "warrant": { … }, "account": "{user_id}/{connection_id}", // repositories.read
      "operations": [{"operation": "repositories.write", "warrant": { … }}] }
  },
  "model": {                                   // optional when the server has a default model
    "name": "claude-sonnet-4-5",
    "credentials": { "warrant": { … }, "account": "…", "cost": 10 },  // inference.generate
    "api": "anthropic",                        // anthropic / openai / responses / gemini / pi
    "baseUrl": "https://api.anthropic.com/v1", // implied for anthropic, mistral, openai
    "maxTokens": 8192, "contextWindow": 200000
  },
  "lun": { "credentials": { … } },             // optional: what lun reads the repository with (default: source's)
  "agent": "build",                            // or "plan"
  "tools": ["read", "ls", "grep", "write", "edit", "todo", "check"], // optional standalone; app sends org policy
  "message": "Write a function that …"             // optional standalone; native app launch starts after projection binding
}
```

`cost` is the credits liaison holds for each model call. Warrants expire
within minutes (the app mints them for 300 s): send fresh ones with each
message, or with `PUT …/credentials`. They are kept in memory only.

Native app launch omits the initial `message`: after creation returns the actual
session ID, the trusted app binds conversation tools and publication branch/root
projections, then sends the first message. This handshake is required for brokered
writer generation; the wire-level optional `message` is not a minting bypass.

Model warrants grant `inference.generate`. Model calls use URL-free connector
egress with the native request payload; the broker derives routing and auth.
Refreshes cannot change organization, provider or account. Native gateway
`api` is validated against the chosen model. `tools: []` denies all writer
tools; omission keeps the full standalone preset, and invalid/unknown tool
restrictions are refused. Current policy and its immutable launch ceiling
survive restart. Full native wire shapes, verified app provisioning and trusted
boundaries are in
[docs/native-writer.md](docs/native-writer.md).

### The log

One JSON object per entry, each with `index`, `type` and `time` (Unix ms):
`user` (`text`), `assistant` (`text`, `calls`: `[{id, name, arguments}]`,
`usage`, `stop`, `model`), `tool_results` (`results`: `[{id, name, content,
isError}]`), `compaction` (`summary`, `firstKept`), `event` (`kind`:
`run_started`, `run_finished`, `aborted`, `error`, `out_of_fuel`,
`interrupted`; `detail`).

## Configuration

| Variable | Default | |
|---|---|---|
| `LODE_PORT` | `8080` | |
| `LODE_WORKDIR` | `/var/lib/lode` | sessions: `sessions/{id}/{session.json,log.jsonl,checkout/}` |
| `LODE_TOKEN` | — | bearer token for the API; unset means unauthenticated (logged loudly) |
| `LODE_LIAISON_URL` | — | liaison, for GitHub/GitLab repositories and models with credentials |
| `LODE_LUN_URL`, `LODE_LUN_TOKEN` | — | lun, for `lun_build` / `lun_call` |
| `LODE_LUN_BUILD_TIMEOUT` / `LODE_LUN_CALL_TIMEOUT` | `3600` / `120` | seconds |
| `LODE_MODEL_API`, `LODE_MODEL_NAME`, `LODE_MODEL_BASE_URL`, `LODE_MODEL_MAX_TOKENS`, `LODE_MODEL_CONTEXT_WINDOW` | — | the server's default model |
| `LODE_MODEL_API_KEY` | — | development: a key sent directly to the default model's endpoint (and only there) |
| `LODE_MAX_STEPS` | `200` | model calls per run |
| `LODE_MODEL_TIMEOUT` / `LODE_GIT_TIMEOUT` / `LODE_CHECK_TIMEOUT` | `600` / `600` / `1800` | seconds |
| `LODE_PACKAGE_CACHE` | — | pre-built linen checkouts, `{cache}/linen/{rev}` |
| `LODE_LINEN_REV` / `LODE_TOOLCHAIN` | `v1.10.0` / `leanprover/lean4:v4.34.0` | what new projects are told to use |
| `LODE_ALLOW_LOCAL` | — | `1`: `file://` repositories and the `scripted` model. Tests only |

## Docker

Images are published to `ghcr.io/typednotes/lode` — `edge` from `main`, and
`latest`, `X.Y.Z` and `X.Y` from release tags. The image carries the Lean
toolchain and linen (`LINEN_REF`, coordinated target `v1.10.0`) pre-built in the package
cache, so a workspace locked to that revision does not rebuild linen.

Use Lode `0.4.0` with Lun `0.3.0`, Liaison `0.6.0` and
Linen `1.10.0`. Historical `0.1.x` cell/DAG deployments do not implement this
native authority contract. Registry/tag publication is release-parent-owned.

### Starting a container from the registry

The package is public: no `docker login` is needed.

```sh
docker pull ghcr.io/typednotes/lode:edge
```

lode is an internal service: typednotes calls it, and it calls liaison and
lun. Put the four on one network and address them by container name; lode
needs no published port for typednotes to reach it at `http://lode:8080`.

```sh
docker network create typednotes            # once; liaison and lun join it too
docker volume create lode                   # sessions, logs and checkouts
LODE_TOKEN="$(openssl rand -hex 32)"        # typednotes needs the same value

docker run -d --name lode --restart unless-stopped \
  --network typednotes \
  -v lode:/var/lib/lode \
  -e LODE_TOKEN="$LODE_TOKEN" \
  -e LODE_LIAISON_URL=http://liaison:8080 \
  -e LODE_LUN_URL=http://lun:8080 -e LODE_LUN_TOKEN=... \
  ghcr.io/typednotes/lode:edge
```

Give typednotes the same `LODE_TOKEN` (it sends `Authorization: Bearer …`).
The other variables are in [Configuration](#configuration); the image already
sets `LODE_WORKDIR`, `LODE_PACKAGE_CACHE` and `LODE_LINEN_REV`, so leave them
alone.

Check it:

```sh
docker logs lode                            # "lode listening on :8080", and warnings for what is unset
docker run --rm --network typednotes curlimages/curl -fsS http://lode:8080/_health && echo ok
```

To reach it from the host too (development), publish on loopback only:
`-p 127.0.0.1:8080:8080`.

Notes:

- **State.** Sessions live in `/var/lib/lode`. A named volume, as above, gets
  the image's ownership; a bind mount must be writable by uid `10001`
  (`chown 10001 /srv/lode`). Credentials are never written there: after a
  restart, sessions resume once typednotes sends fresh warrants.
- **Outbound network.** Credentialed model and repository calls stay brokered;
  there are no direct signed-tarball downloads. Public repository clones and
  `git`/`lake` dependency/toolchain acquisition still need build-time egress.
  The image carries the system CA bundle; container/network isolation remains
  part of the trusted build boundary.
- **One lode per trust domain.** `bash` runs whatever the model asks inside the
  container, so the container is the isolation boundary: give it no
  credentials of its own and do not share it across organisations (see
  [Project status](#project-status)).
- **Platform.** Images are `linux/amd64` only. On Apple Silicon add
  `--platform linux/amd64` (emulated, so `lake build` is slow), or build the
  image locally.
- `podman` takes the same commands.

Standalone, for trying lode without liaison (a public repository, read-only,
and a model key sent directly to the provider):

```sh
docker run --rm -p 127.0.0.1:8080:8080 -v lode:/var/lib/lode \
  -e LODE_TOKEN=dev \
  -e LODE_MODEL_NAME=claude-sonnet-4-5 -e LODE_MODEL_API_KEY="$ANTHROPIC_API_KEY" \
  ghcr.io/typednotes/lode:edge
```

### Building the image

To build the image locally:

```sh
docker build -t lode .
```

## Design

lode takes its shape from two agents that got it right:

- **From [pi](https://github.com/badlogic/pi-mono)**: a small core and a short
  system prompt (the model knows how to code; it needs its tools, its
  environment and its mission); a few sharp tools (`read`, `write`, `edit`,
  `bash`, plus read-only `ls`/`grep`); one provider-independent message model
  over several wire formats; a session as an append-only log; `AGENTS.md`
  context files; **steering**; output truncation limits; **compaction** by
  summary.
- **From [OpenCode](https://opencode.ai)**: a client/server split (the agent
  *is* an HTTP server with sessions and messages); **agents** with tool
  allowlists; a `todo` tool; compiler **diagnostics fed back after edits**
  (whole-`lake build` compiler feedback); exact-string `edit`; bounded Lean LSP
  diagnostics, hover, goals, completion and definition through ephemeral workers.

And from typednotes' service design: a loop that is
**total by construction**, tool arguments **parsed into typed values** at the
boundary where the model's text becomes an action, and authority that is only
ever the intersection of organization/session tool settings, the selected agent,
and the independently checked native connector/warrant ceilings.

lode reuses before it writes: JSON through derived `ToJson`/`FromJson`,
liaison's format through `Liaison.Wire`, and linen's URL encoding, dates,
commit ids, filesystem capabilities and middleware; Lake's own manifest
parser.

## Project status

The **0.4.0 release** pipeline passes with the actual app, compiled
Lode, real credential broker, disposable local Git, and compiled Lun, including
tool execution, publication/adoption and denied operations. Supporting suites
pass **101 app API tests**, **24 browser groups**, **655 real broker HTTP cases**
and **69 compiled-runtime cases**. Provider replies remain controlled fixtures;
live paid-provider/OAuth conformance and real-model implementation reliability
are unmeasured.

Warrants are refreshed by the caller; Lode does not mint them. Tool policies and
credential identities are monotonic across refresh/restart. The Lean proofs
bound named tool/native operations; arbitrary allowed shell commands, project
Lakefiles, filesystem/transport FFI and container isolation remain trusted
boundaries. The dedicated `lsp` tool and proof-bounded Eff trial bridge are
verified by 63 LSP dispatcher calls and seven real runtime bridge groups.
There is no unrestricted writer web-fetch fallback. See
[`AGENTS.md`](AGENTS.md) and [native writer integration](docs/native-writer.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
