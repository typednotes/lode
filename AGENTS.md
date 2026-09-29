# lode — agent notes

`lode` is the coding agent of typednotes: an HTTP service (Lean 4, on
`linen` pinned `v1.9.0`, speaking to liaison with liaison's own wire module
`Liaison.Wire`, pinned `v0.5.5`) that runs model-driven sessions over a branch of a
git repository and writes the Lean projects `lun` builds and serves
(functions, graphs, `lun.json`; lun's and linen's vocabulary — lun ≥ 0.2.0
has no `cells`/`dags` aliases, and neither has lode). lode is the writer; lun is the runner — do not confuse
the two. See `README.md` for the API and the design.

## Layout

Pure modules (unit-tested with `#guard` in `LodeTest/`):

- `Lode/Validate.lean` — lode's grammars: ids, project path, model base URL,
  and `resolve`/`writable` (tool paths: never outside the checkout, never
  into `.git`/`.lake`). Repository URLs and branch names are linen's
  `System.Git.Remote` (`Repository.parse`, `isBranchName`), which lun uses
  too, so both agree.
- `Lode/Liaison.lean` — credentials (a warrant decoded by liaison's own
  `Liaison.Wire.decodeWarrant`, the grant read with `Request.ofWarrant`, the
  account checked with `accountMatchesResource`) and `call`, which builds the
  request with `Body.provider` and reads the reply with `decodeReply`. JSON
  crosses to liaison's `Data.Json.Value` through linen's `Data.Json.Bridge`.
- `Lode/Message.lean` — the provider-independent conversation (`Message`,
  `ToolCall`, `ToolResult`, `Reply`), the log (`Entry`, JSON both ways) and
  `context` (what the model is sent: since the last compaction, every tool
  call answered — `answerDangling`).
- `Lode/Model.lean` — `Config`, the Anthropic Messages and OpenAI Chat
  Completions wire formats (`anthropicRequest`/`anthropicReply`,
  `openaiRequest`/`openaiReply`), the `scripted` API (tests), and `complete`
  (liaison or direct transport; retries on 408/429/5xx with linen's
  `RetryPolicy`/`delayFor`, following a relayed `Retry-After`, stopping on
  abort).
- `Lode/Tools.lean` — tool specs, `Args.parse` (the model's text → typed
  arguments), `numberLines`, `applyEdit`, truncation, and `run`/`execute`
  (IO, through `Env`, which the session provides).
- `Lode/Compaction.lean` — when to compact, where to cut (before an
  assistant entry), the summarizer's transcript and instructions.
- `Lode/Prompt.lean` — agents (`build`, `plan`), the system prompt (lun's
  contract: functions, effects, graphs, `lun.json`, the workflow), context files.
- `Lode/Spec.lean` — the session request (`SessionSpec.parse`) and
  `CredentialSet` (in memory only).
- `Lode/Lun.lean` — `lun.json`, the build request, the lun client
  (`submit`/`build` (polls)/`call`) and renderings for the model.

IO modules:

- `Lode/Process.lean` — the environments commands run with: `hermeticGit`
  (linen's, plus a fixed identity) and `toolEnv` (without lode's own
  variables). Commands run through linen's `System.Process.run` (deadline,
  abort flag, process group killed); `check` reads `lake build` with linen's
  `System.LakeLog`.
- `Lode/Http.lean` — one request over linen's client.
- `Lode/Workspace.lean` — the checkout: `open` (git clone, or the GitHub
  tarball / GitLab archive through liaison, made a local repo), `changes`
  (`git diff --raw` against `localBase`), `publish` (git push, or GitHub
  blobs→tree→commit→fast-forward ref, or a GitLab commit with actions),
  `seedCache` (linen from the package cache; the locked revision read with
  Lake's own `Lake.Manifest.parse`).
- `Lode/Session.lean` — sessions (persisted metadata, append-only log,
  credentials in memory), runs (`send`: start or steer; `loop`: structural
  in fuel; `tryFinish`/`finish`: atomic with the queue; abort), the tools'
  `Env` (publish, lun), the registry.
- `Lode/Server.lean` — routes. `Main.lean` — environment.

## Running tests

```
lake test          # unit tests
test/e2e.sh                   # scripted model, file:// repository, real git/lake
test/liaison.sh               # GitHub/GitLab/Anthropic through test/mock_liaison.py
test/lun.sh ../lun ../linen   # with a real lun (>= 0.2.0) and a linen checkout
```

`LODE_E2E_KEEP=1` keeps a test's work directory. The first build copies
nothing: if you have lun built next door, `cp -R ../lun/.lake/packages/linen
.lake/packages/` saves building linen (same revision, same toolchain).

## Conventions

- As in linen and lun: no `sorry`; document definitions; `── … ──` section
  banners. No `partial def`: the agent loop is structural in its fuel, other
  loops are `repeat` polling or structural recursion.
- Everything that interprets untrusted input — requests, the model's tool
  arguments, liaison's and the hosts' answers, lake's output — is pure and
  unit-tested.
- **Stdlib and linen first; never re-implement them.** JSON shapes are
  structures with derived `ToJson`/`FromJson` (optional fields `Option`, written
  as `null` when absent), optional object fields `Json.opt`; liaison's format
  is `Liaison.Wire`; URL encoding `Network.HTTP.Types.urlEncode`; dates
  `Data.Time.ISO8601`; commit ids `System.GitFn.CommitSha`; the workspace
  boundary linen's `FileSystem` capability (`Env.capability`,
  `ScopedPath.check?`); request size and health `requestSizeLimit` /
  `healthCheck`; `lake-manifest.json` `Lake.Manifest.parse`; commands
  `System.Process`; lake's output `System.LakeLog`; repository URLs and
  branches `System.Git.Remote`; the bearer token `Crypto.ConstantTime`;
  retry delays `Network.HTTP.Client.delayFor`. What remains hand-written is
  the agent's own logic (tools' rendering, compaction, the loop) and lode's
  own grammars. Before adding a helper, look in linen (`docs/modules.md`)
  and core; code lun needs too belongs in linen.
- Credentials are never persisted, logged, or returned (no `ToJson`/`Repr` on
  `Credentials`). The operator's direct model key is only ever sent to the
  operator's configured endpoint (`Session.transport`).
- Tool failures are results for the model, never exceptions that end a run.
- Lean 4 keyword pitfalls met here: `meta` and `local` cannot be field or
  variable names; `/-` inside a doc comment (e.g. `+/-`) opens a nested
  comment.

## Git

**Never run `git push` in this repo.** Commits are fine when asked for;
pushing is always left to the user.

## Known gaps (named, not silent)

- **No run against a real model has been made here** (no API key was
  available). Both wire formats are unit-tested, exercised end to end against
  a mock liaison (Anthropic format), and a real `api.anthropic.com` /
  `api.openai.com` answered lode's requests (with a `401` for a fake key:
  lode's outbound TLS client, framing and error reporting verified; lode
  itself serves plain HTTP on an internal network). Prompt quality — whether a model
  reliably drives the workflow to a green lun build — is unmeasured.
- **Warrants expire** (the app mints them for 300 s) and lode cannot mint or
  refresh them: a long run fails with `expired` unless the caller refreshes
  credentials (`PUT …/credentials`, or with each message). The run then ends
  with an error naming the cause; the next message resumes the session.
- **No attenuation.** `typednotes/docs/services/agent.md` asks the agent to
  `narrow` its warrant before each sub-call and to prove
  `run_authority_bounded`. lode forwards warrants as given (it has no root
  key); authority is bounded by what the caller mints, not narrowed further.
- **The model goes through liaison's generic `provider` egress** (liaison
  0.5.3's `inference` call kind is still a stub), charged
  the flat `cost` per call (liaison's `inference` kind is a stub): no token
  metering. The request must fit liaison's UTF-8 body; replies are relayed
  whole (no streaming, so progress is visible per step, not per token).
- **Abort** stops at the next step, and kills a running `bash`/`check`
  process group or a lun wait, but an in-flight model call runs to its end
  (or `LODE_MODEL_TIMEOUT`).
- **The branch must exist** (empty repositories are not supported: GitHub's
  Git Data API refuses them). If someone else pushes to the branch, `publish`
  refuses (fast-forward only) and there is no `sync`/rebase tool yet: start a
  new session from the new head.
- **GitLab**: the branch-moved check and the commit are two calls (a small
  race window); symbolic links cannot be published through its API.
- **Public repositories without credentials are read-only** (`publish`
  fails); `git` push works only in local mode.
- **Types are not a sandbox, and neither are the tools.** `bash` runs
  anything the container allows, and `lake build` runs a project's lakefile.
  Path checks (lexical, then symbolic links resolved for writes) protect
  lode's own bookkeeping (`.git`, `.lake`, the checkout boundary), not the
  host: the container is the isolation boundary. lode's own variables
  (`LODE_TOKEN`, `LODE_LUN_TOKEN`, `LODE_MODEL_API_KEY`, …) are removed from
  what the model runs (`Process.toolEnv`), but every session runs as the same
  user on the same volume: a determined `bash` can read `/proc/{lode}/environ`
  and other sessions' checkouts and logs. **Run one lode per trust domain**
  (e.g. per org), with no credentials of its own.
- **One process, local state**: sessions live on the volume of one lode; no
  replication, no cross-instance locking. Long-polling holds a request
  thread (≤ 60 s); there is no SSE stream.
- **After a restart** sessions and logs are intact but hold no credentials;
  an interrupted run is recorded, and any tool call it left unanswered is
  answered with an error on the next model call.
- **OpenAI-compatible endpoints get `max_tokens`**, which OpenAI's reasoning
  models refuse (they want `max_completion_tokens`). Text only: no images.
- **Compaction** estimates tokens (provider usage when reported, else
  characters / 4) and summarizes with the session's own model; it has only
  been exercised through its pure parts and the scripted model.
- **lun's live graph sessions are not used.** lun 0.2.0 serves graph
  sessions (`POST …/graphs/{name}/sessions`, then `POST /v0/sessions/{id}`
  updates some inputs and answers what changed); lode uses builds, function
  calls and one-shot graph runs only. Verified against lun `fe6af51`
  (0.2.0 + 3).
- **Graphs are inputs and functions only**, because lun refuses linen's other
  reactive operators (`map`, `scan`, `combineLatest` with a lambda, …) in a
  graph; the prompt says so and asks for that logic to go into functions.
- **The container image has not been built here**; the Linux link is
  unverified (lode's own link was verified on macOS).
