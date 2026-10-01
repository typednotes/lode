# lode — agent notes

`lode` is the coding agent of typednotes: an HTTP service (Lean 4, on
`linen`, speaking to liaison with liaison's own wire module
`Liaison.Wire`) that runs model-driven sessions over a branch of a
git repository and writes the Lean projects `lun` builds and serves
(functions, graphs, `lun.json`; lun's and linen's vocabulary — lun ≥ 0.2.0
has no `cells`/`dags` aliases, and neither has lode). lode is the writer; lun is the runner — do not confuse
the two. See `README.md` for the API and the design.

Coordinated release set: **Lode 0.4.2 / Lun 0.3.0 / Typednotes 0.7.2 /
Linen 1.10.0 / Liaison 0.6.0**. Package locks, image defaults and new-project
defaults use this set. Publishing local release tags and deploying remain the
user's actions.

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
  request with `Body.connector` and reads the reply with `decodeReply`. Native
  `repositories.*` and `inference.generate` calls select named-operation tokens;
  `Liaison.Wire.NativeContext` carries the actual session and truthful client.
  Generic provider egress is not a fallback. JSON
  crosses to liaison's `Data.Json.Value` through linen's `Data.Json.Bridge`.
- `Lode/Message.lean` — the provider-independent conversation (`Message`,
  `ToolCall`, `ToolResult`, `Reply`), the log (`Entry`, JSON both ways) and
  `context` (what the model is sent: since the last compaction, every tool
  call answered — `answerDangling`).
- `Lode/Model.lean` — `Config`, Messages, Chat Completions, Responses, Gemini
  and Radius Pi/SSE serializers/reply parsers, the `scripted` API (tests),
  reasoning/signature replay, `boundedHistory` for retired tools, and `complete`
  (liaison or direct transport; retries on 408/429/5xx with linen's
  `RetryPolicy`/`delayFor`, following a relayed `Retry-After`, stopping on
  abort).
- `Lode/Tools.lean` — tool specs, `Args.parse` (the model's text → typed
  arguments), `numberLines`, `applyEdit`, truncation, and `run`/`execute`
  (IO, through `Env`, consuming `AuthorizedArgs`). `lun_call` carries typed
  input-only data, never model-selected execution policy or credentials.
- `Lode/ToolPolicy.lean` — finite tool operations, `BoundedPolicy`, and
  kernel-checked reflexive/transitive narrowing and launch-ceiling bounds.
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
- `Lode/Workspace.lean` — the checkout: `open` (public/local git clone, or
  brokered immutable branch/tree/file views materialized using private
  `NativeFile` witnesses), `changes` (`git diff --raw` against `localBase`),
  and `publish` (a subtree-scoped native commit plan with an expected head).
  The broker uses GitHub `updateRefs` head CAS or GitLab generated smart-HTTP
  receive-pack CAS; deletion requires independent authority. No archive,
  signed download, generic HTTP or racy REST-commit fallback is used. Local-mode
  git publication is separate from credentialed native publication.
  Also `seedCache` (linen from the package cache; the locked revision read with
  Lake's own `Lake.Manifest.parse`).
- `Lode/Session.lean` — sessions (persisted metadata, append-only log,
  credentials in memory), runs (`send`: start or steer; `loop`: structural
  in fuel; `tryFinish`/`finish`: atomic with the queue; abort), the tools'
  `Env` (publish, lun), the registry, and a policy mutex that serializes actual
  tool execution with monotonic narrowing. Metadata preserves the launch ceiling;
  credentials remain in memory and are re-read for model calls/compaction.
- `Lode/Server.lean` — routes. `Main.lean` — environment.

## Running tests

```
lake test          # unit tests
test/e2e.sh                   # scripted model, file:// repository, real git/lake
test/liaison.sh               # GitHub/GitLab/Anthropic through test/mock_liaison.py
python3 test/native.py .lake/build/bin/lode # all native protocols, policy and restart
test/lun.sh ../lun ../linen   # with the coordinated Lun/Linen source checkouts
```

`LODE_E2E_KEEP=1` keeps a test's work directory. Before releases are published,
use the sibling path-override Lake workspace (`lake build lode:exe +LodeTest`).
The real broker suite also executes compiled Lode model/Workspace callers;
the app's `scripts/test_native_connectors.py --runtime --real-writer` exercises
the full app → Lode → broker → local Git → Lun pipeline. See
`docs/native-writer.md` for reproduction and the distinction between fixtures
and paid-provider conformance.

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

## Verified contracts and remaining boundaries

- **Real local pipeline verified.** The release-preparation suites pass 99 app
  API tests, 24 browser groups, 655 real broker HTTP cases and 69 compiled-runtime
  cases, plus the full app/compiled-Lode/broker/local-Git/compiled-Lun positive
  and denial pipeline. Provider replies are controlled local fixtures; paid
  provider/OAuth conformance and real-model implementation quality remain unmeasured.
- **Warrants expire** (the app mints them for 300 s) and lode cannot mint or
  refresh them: a long run fails with `expired` unless the caller refreshes
  credentials (`PUT …/credentials`, or with each message). The run then ends
  with an error naming the cause; the next message resumes the session.
- **Authority is narrowed and intersected.** The app supplies organization tool
  settings at launch and applies narrowing before acknowledging policy edits.
  `BoundedPolicy`/`AuthorizedArgs` prove dispatch stays within the launch/current
  tool ceiling and agent selection. Trusted broker projections bind conversation
  tools and publication branch/subtree; each native operation intersects
  organization, connection, cell and warrant scopes. Lode does not mint warrants
  or possess the HMAC root key. These guarantees are not a general sandbox.
- **Native model calls** use `inference.generate`, bounded inline local function
  metadata/replay and typed session context. Radius Pi/SSE is enabled and tested.
  Replies are buffered; the app observes steps, not streamed provider tokens.
  Declared per-call costs are held/settled by the broker; reported token usage is
  tracked separately, not a promise of token-priced billing.
- **Abort** stops at the next step, and kills a running `bash`/`check`
  process group or a lun wait, but an in-flight model call runs to its end
  (or `LODE_MODEL_TIMEOUT`).
- **The branch must exist** (empty repositories are not supported: GitHub's
  Git Data API refuses them). If someone else pushes to the branch, `publish`
  refuses (fast-forward only) and there is no `sync`/rebase tool yet: start a
  new session from the new head.
- **Native repository limits:** unambiguous `[owner,repo]`, SHA-1 commits,
  regular files and bounded complete trees. Nested GitLab namespaces, SHA-256
  repositories and symlinks/submodules are refused. Both native publication
  backends consume an exact expected-head condition; branch rewinds are tested.
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
- **Text/local tools only:** reasoning Chat models receive
  `max_completion_tokens`; Responses use stateless encrypted reasoning replay.
  Provider-hosted tools and remote retrieval are refused. Classifier-only models
  cannot drive the writer. No image/multimodal writer workflow is claimed.
- **Compaction** estimates tokens (provider usage when reported, else
  characters / 4) and summarizes with the session's own model; it has only
  been exercised through pure, scripted and native protocol fixtures. Retired-tool
  history recovery preserves the user task without reviving replay authority.
- **Lode does not own live graph sessions.** Lun serves graph
  sessions (`POST …/graphs/{name}/sessions`, then `POST /v0/sessions/{id}`
  updates some inputs and answers what changed); lode uses builds, function
  calls and one-shot graph runs only; the app owns live registration and feeds.
- **Graphs are inputs and functions only**, because lun refuses linen's other
  reactive operators (`map`, `scan`, `combineLatest` with a lambda, …) in a
  graph; the prompt says so and asks for that logic to go into functions.
- **The container image has not been built here**; the Linux link is
  unverified (lode's own link was verified on macOS).
- **Bounded LSP and Eff trials are implemented:** `lsp` uses ephemeral actual
  Lean workers with typed document/method/location bounds; `lun_call` consumes
  authenticated, launch/current-narrowed app authority. See `docs/lsp.md` and
  `docs/runtime-bridge.md` for proofs, real tests and trusted boundaries. There
  is no unrestricted web-fetch or model-chosen execution-authority fallback.
