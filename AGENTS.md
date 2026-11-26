# AGENTS.md — lode

<!-- agents-md standard v6 — github.com/ngrislain/agents. Refresh with the agents-md skill. -->

Instructions for coding agents (Claude Code, Codex, pi, opencode, …) and for humans working on
this project. `CLAUDE.md` imports this file; edit this one.

## Project

`lode` is the coding agent of typednotes: an HTTP service (Lean 4, on
`linen`, speaking to liaison with liaison's own wire module
`Liaison.Wire`) that runs model-driven sessions over a branch of a
git repository and writes the Lean projects `lun` builds and serves
(functions, graphs, `lun.json`; lun's and linen's vocabulary — lun ≥ 0.2.0
has no `cells`/`dags` aliases, and neither has lode). lode is the writer; lun is the runner — do not confuse
the two. See `README.md` for the API and the design.

The development branch uses **Linen 3.0.0** in its package lock, image cache,
and new-project defaults. The **Lode 0.4.2 / Lun 0.3.0 / Typednotes 0.7.2 /
Linen 1.10.0 / Liaison 0.6.0** release set is documented in `README.md` and
`docs/release-0.4.2.md`. Publishing local release tags and deploying remain
the user's actions.

| Task | Command |
| --- | --- |
| Install | Lean toolchain from `lean-toolchain` via [elan](https://github.com/leanprover/elan); `git`, `bash`, `jq` and linen's native build dependencies (see `Dockerfile`); `lake build` fetches the dependencies pinned in `lake-manifest.json` |
| Type-check | `lake build --wfail` |
| Test | `lake test`; `bash ci/test-require-main-ci.sh`; `test/e2e.sh`; `python3 test/cli.py`; `python3 test/python_client.py`; `python3 test/graph_svg.py`; `python3 test/lsp.py`; `test/liaison.sh`; `python3 test/native.py .lake/build/bin/lode`; `test/lun.sh ../lun ../linen` (see Running tests) |
| Lint | `lake lint --builtin-only` (built-in checks) |
| Build / release | `lake build lode`; `docker build -t lode .`; release: a `v*.*.*` tag push triggers `.github/workflows/docker-publish.yml` (push only when explicitly requested) |
| CLI (applications) | `lake exe lode --help` |

Before declaring a change done, run type-check, tests and lint, and report their real output.

## Permissions: what to do freely, when asked, and only after confirming

**Do freely** — reversible and local:
- read, search, and run type-checkers, tests, linters, formatters and local builds;
- edit files in the working tree within the scope of the task, including `docs/`, `reviews/`,
  `NOTES.md`, `TODO.md`, specs and tests;
- create scratch files in git-ignored directories (`output/`, `.cache/`, `tmp/`);
- read shell history and logs to spot repetitive work (see "Suggest automating repeated work").

**Only when the user asks** — do not initiate:
- `git commit`, creating or switching branches, stashing, rebasing a local branch;
- adding, removing or upgrading dependencies (propose the change and why);
- changing the machine outside the repository — global installs, dotfiles, symlinks, services,
  shell profiles — and recording each change in the manifest (see "Manifest of system changes");
- runs that are long (> ~10 min), costly (GPU, cluster, cloud, paid APIs) or touch shared
  resources (shared caches, staging data);
- clearing `.cache/` or `output/`, or forcing a cache refresh, when the content is slow or costly
  to produce again.

**Confirm explicitly every time**, even if a similar action was approved earlier — approval does
not carry over to a new context:
- `git push` only when explicitly requested by the user for that operation. Direct pushes to
  `main`/`master` are permitted only when explicitly specified. A request specifying the push
  scope (repositories, remote, branches and any tags), including an explicit command or batch,
  counts as confirmation; do not ask again for the same operation. Approval does not extend to
  later pushes. Never force-push or rewrite pushed history;
- opening, merging or closing a PR/MR, posting review comments, tagging, releasing, publishing a
  package or image;
- deploying to any environment (dev, staging, prod);
- publishing outside the repo: Confluence, Google Docs/Sheets, Slack, email, issue trackers;
- deleting or overwriting anything not recreated by a command in this repo: branches, remote
  resources, datasets, buckets, tables, experiment outputs;
- changing infrastructure, permissions, secrets or credentials.

**Never**: commit secrets or customer data; skip hooks (`--no-verify`); rewrite pushed history;
weaken a type-check, a test or a lint rule to make it pass; claim a check passed without running it.

## Repository layout and the documents it keeps

| Path | Audience | Content | Keep in sync with |
| --- | --- | --- | --- |
| `docs/` | humans, high level | project, architecture, algorithms, code map — a hierarchy of Markdown files illustrated with SVG figures | the code, every change |
| `README.md` (root and per package) | users and contributors, close to the code | install, usage, examples, how the code is organised | the code it sits next to |
| `SPEC.md` (per module/package) | humans first | the contract the code must fulfil | types and tests check it |
| `scripts/` | contributors | repository-maintenance helpers, including `rebase-on-main.sh` | developer workflow and tests |
| `reviews/` (git-ignored) | reviewers | reviews of commits and PRs: explanation, SVG figures, suggested comments and fixes | — (dated snapshots) |
| `output/` (git-ignored) | users of the application | large, binary or reproducible outputs of runs | — (regenerated by the CLI) |
| `.cache/` (git-ignored) | the code | cached results of slow downloads and computations | — (safe to delete) |
| `CHANGELOG.md` | users of a released artifact | one entry per version, newest on top | every release |
| `LOGBOOK.md` | humans re-running experiments | one entry per experiment, newest on top, with repeatability info | every experiment |
| `TODO.md` | everyone | planned but not executed work | when planning or finishing work |
| `NOTES.md` (anywhere) | humans and agents | things worth knowing that are not definitive documentation | when something surprising is learned |

### `docs/` — high-level documentation

- A hierarchy with an index at `docs/README.md` linking every page. Typical sections:
  `docs/project/` (goals, scope, decisions, roadmap), `docs/architecture/` (components, data
  flow, deployment), `docs/algorithms/` (methods, math, complexity, trade-offs), `docs/code/`
  (module map, key types, extension points).
- Illustrate with SVG figures stored next to the page that uses them (`docs/architecture/figures/`).
  SVG is the editable source: hand-written or generated by a committed script, legible at page
  width, in light and dark backgrounds, with a `<title>` and `<desc>`. Do not commit rendered PNGs.
- `docs/` explains *why* and *how it fits together*; `README.md` files explain *how to use and
  modify* the code next to them. Link rather than repeat; one canonical page per subject.
- Keep `docs/` in sync: a change to behaviour, architecture, an algorithm or a public interface
  updates the affected pages and figures **in the same change**. Separate measured results from
  expectations and proposals.

### `scripts/` — repository maintenance

- All runnable helpers follow the same interface standard as the application CLI:
  a colourful, structured terminal UI (plain when piped, `TERM=dumb` or `NO_COLOR` is set),
  self-documenting `--help` with examples and effective defaults plus their sources, and
  actionable errors. Missing arguments use safe defaults or prompt interactively on a TTY;
  non-interactive runs never hang waiting for input and identify any required flag explicitly.
- Keep editable defaults in a TOML file, normally `scripts/defaults.toml`, grouped by command.
  If a script manages multiple runs/sessions, organise their defaults under named TOML tables
  and select them explicitly with `--run` / `--session`; do not duplicate scripts or hard-code
  session settings. Document precedence: flags > environment > selected run/session >
  command defaults > built-in fallbacks. Help shows the resolved values and their sources.
- State-changing helpers show the resolved plan, prompt before applying it and support `--yes`
  for non-interactive use and `--dry-run` for a non-mutating preview. Defaults never bypass
  confirmation or the Permissions section.
- Git repositories keep an executable `scripts/rebase-on-main.sh`: fast-forward local `main`
  from `origin/main`, return to the original branch, and rebase it onto the updated `main`.
  Allow an explicit remote override; on `main`, only fast-forward it. In a monorepo, share one
  helper at the Git root rather than adding a copy per package.
- Provide `--help` and a non-mutating `--dry-run`. Refuse a dirty working tree (including
  untracked files), detached HEAD, and unfinished Git operations. Never stash, reset, discard
  changes or push automatically. If updating `main` fails, return to the original branch;
  if rebasing conflicts, stop there and explain `git rebase --continue` / `--abort`.
- Document how to invoke it and test it against temporary local repositories, never the working
  checkout. Preserve existing helpers rather than overwriting them blindly. Creating the helper
  is not permission to execute a rebase: the Permissions section still applies.

### `SPEC.md` — one contract per module/package

- Every module, package or component with a public surface has a `SPEC.md` beside its code: a short,
  human-readable statement of what it guarantees — purpose, inputs/outputs, invariants, error
  behaviour, performance bounds, what it explicitly does not do.
- The spec is the source of truth. Types encode as much of it as the language allows; tests check
  the rest. When code and spec disagree, fix one of them deliberately and say which.
- Number the clauses (`S1`, `S2`, …) so tests and reviews can cite them.

### `reviews/` — reviews of commits and PRs

One directory per review, `reviews/YYYY-MM-DD-<slug>/`, with a `README.md` (summary, walkthrough,
findings ranked by severity, suggested comments ready to paste, suggested fixes as diffs) and
`figures/*.svg`. A video only when the user asks for one. `reviews/` is **git-ignored**: reviews
are local working documents, not project history. Posting them anywhere requires confirmation
(see Permissions).

### `output/` — generated results, git-ignored

What an application produces that is large, not text (images, videos, models, archives, binary
tables) or reproducible from the code and its inputs goes to `output/`, which is **git-ignored**.
Organise it by command and run (`output/<command>/<run-id>/`), write next to each result what
produced it (command, parameters, commit), and make the location a CLI option with `output/` as
the default. Anything worth keeping is either reproducible from the repo (then it stays in
`output/`) or published deliberately (a release, a bucket, a document — see Permissions); small,
reviewed, hand-curated text results may be committed elsewhere, e.g. in `docs/`.

### `.cache/` — caching slow objects, git-ignored

Anything slow or costly to obtain — a large download, a long computation, a remote query — is
cached under `.cache/` (**git-ignored**), with the most idiomatic library of the language: in
Python `joblib.Memory` for function results, Parquet (or JSON for small, human-readable data) for
tables keyed by their parameters; elsewhere the equivalent (`cacache`/file caches in JS, `cached`
or file caches in Rust, …).
- The cache key covers everything that determines the result: parameters, input versions or
  checksums, and a code version. Cache only results that cannot change for a given key — never
  "the latest" of something live (pin a date, a version or a completed time window instead).
- Deleting `.cache/` must always be safe: it costs time, never correctness. Downloads are
  verified (checksum or size) before being cached.
- The CLI offers `--no-cache` and `--refresh`, and the location is configurable (config file or
  environment variable), with `.cache/` as the default.

### `CHANGELOG.md` — only if the project is released as a versioned artifact

Library, image, executable, model: one section per version, newest on top, following
[Keep a Changelog](https://keepachangelog.com) and [SemVer](https://semver.org). Unreleased changes
accumulate under `## [Unreleased]`. Bump the version and the changelog in the same change.

### `LOGBOOK.md` — only if the project runs experiments

One entry per experiment, newest on top, readable by a human who was not there: date, question,
setup, result (with numbers), conclusion, and how to repeat it — commit hash, exact command,
parameters, seeds, data snapshot, links to outputs and dashboards. Failed and inconclusive
experiments are logged too.

### `TODO.md` and `NOTES.md`

- `TODO.md`: planned but not executed work, as a checklist grouped by theme, with enough context to
  pick an item up cold. Remove items when done (the history is in git and the changelog).
- `NOTES.md`: anywhere something should be known by a human or an agent and is not definitive
  documentation — gotchas, findings, dead ends, external constraints, open questions. Promote a note
  to `docs/` or a `README.md` once it becomes definitive.

## Code

### Types: use the strongest standard checking the language offers, maximally

- Use the standard type-checker of the language/framework in its strictest practical mode, run it in
  CI, and keep it at zero errors. In this project: Lean 4 (toolchain `leanprover/lean4:v4.36.0`, pinned in `lean-toolchain`), type-checked by `lake build`, with every theorem checked by Lean's kernel. `autoImplicit` stays on (Lean's default: it only automates implicit binders, which are still fully checked), and CI builds with `--wfail` (`leanprover/lean-action@v1` `build-args`): warnings, including `declaration uses 'sorry'`, fail the build. Run `lake build --wfail` locally. "No `partial def`" remains a project convention (see Project-specific notes), not a compiler-enforced setting.
- Make illegal states unrepresentable: precise types, enums/sum types over strings and flags, new
  types for identifiers and units, immutable data by default. Avoid `Any`, casts and ignores; when
  one is unavoidable, scope it narrowly and justify it in a comment.

### Modularity and docstrings

- Organise the code in cohesive modules with explicit, minimal public interfaces and acyclic
  dependencies. One canonical implementation per concern; delete dead paths rather than keep them.
- Every public module, class and function has a docstring written for a human user: what it is
  for, how to call it, what it returns or raises, and an example when usage is not obvious. Explain
  *why* in comments, not *what*.

### One CLI per application

An application project (anything run rather than imported) exposes **a single command-line entry
point** with a short name, e.g. `uv run lode <command>` in Python (a `[project.scripts]` entry),
`npx lode`, `cargo run --bin lode`. Every operation — run, train, evaluate, serve, inspect,
publish — is a subcommand of it, not a loose script. Repository-maintenance helpers in
`scripts/` are a narrow exception, not alternative application entry points.

- **Self-documented**: `lode`, `lode --help` and `lode <command> --help` at every level list
  the commands, arguments, defaults and an example. Running a command with no arguments prints help
  rather than doing something surprising.
- **No dead ends on missing arguments**: each argument either has a default or is asked for
  interactively. Defaults live preferably in a TOML config (`lode.toml`, or `[tool.lode]` in
  `pyproject.toml`), with hard-coded fallbacks in the code; precedence is
  flag > environment variable > config file > hard-coded default, and `--help` shows the effective
  value and where it came from.
- Interactive prompts only when stdin is a TTY; otherwise (CI, agents, pipes) fail fast with a message
  naming the missing flag. Destructive or outward-facing commands ask for confirmation and accept
  `--yes` and `--dry-run`.
- **Rich, colourful terminal UI** preferably: coloured and structured help, tables, progress bars,
  spinners, syntax-highlighted output and interactive prompts/selections (Python: `rich` +
  `rich-argparse`, Typer, Textual for full TUIs; JS: `@clack/prompts`, `ink`; Rust: `clap` with
  colours, `indicatif`, `ratatui`; Go: Charm's `bubbletea`/`lipgloss`). Degrade gracefully: plain
  output when not a TTY, and honour `NO_COLOR`.
- Large, binary or reproducible results go to `output/` (overridable with `--output`); slow
  intermediate results are cached in `.cache/` (`--no-cache`, `--refresh`) — see above.
- Data goes to stdout, logs and progress to stderr; exit codes are non-zero on failure. Offer
  `--json` where the output is consumed by other programs.

### Tests

- Tests do two jobs: **illustrate** every unit and higher-level functionality working (they are
  executable examples — readable, named after the behaviour), and **check** that the code fulfils its
  `SPEC.md` (cite clause ids, e.g. `test_s3_rejects_empty_window`).
- Cover unit, integration and end-to-end levels as relevant; prefer property-based tests for
  invariants. Every bug fix comes with a regression test. Tests are deterministic and fast by default;
  slow or networked tests are marked and opt-in.

## Working style

- Keep changes focused on the task; mention unrelated issues in `TODO.md` or `NOTES.md` instead of
  fixing them silently.
- Update code, types, tests, `SPEC.md`, `docs/`, `README.md`, `CHANGELOG.md` and figures together.
- Report faithfully: what was run, what passed, what failed, what was skipped.

### Manifest of system changes

Changes to the machine outside the repository are recorded so they can be tracked and reverted:
installing or upgrading tools globally (`brew`, `uv tool`, `pipx`, `npm -g`, `cargo install`),
editing dotfiles and configuration under `$HOME`, creating symlinks, services, launch agents or
cron jobs, changing shell profiles or system settings. (Changes inside the repo are tracked by
git; cloud resources by their own infrastructure-as-code.)
- **Where**: the XDG state directory, `${XDG_STATE_HOME:-~/.local/state}/<tool>/` — an
  application uses its own name; an agent acting by hand uses `agents/`, appending one JSON
  object per line to `manifest.jsonl`:
  `{"time": "…", "project": "…", "command": "…", "changes": ["…"], "revert": "…"}`.
- **What**: the exact command, every path or setting it changed, and what reverting needs — the
  inverse command, the backup path or the previous value. Back up a file before overwriting it.
- **Applications** that make such changes (installers, linkers, setup commands) write the
  manifest themselves and offer `history` and `revert` subcommands. A revert undoes newest first,
  skips an action whose path changed since, and is itself recorded.

### Undo log for mutating actions

An application whose actions mutate state — files, configuration, links, services, databases,
anything not regenerated by a command — keeps an **undo log**: one record per mutation, enough to
revert it.
- **At the scope of what changed**, so the log sits next to the state it can restore:

  | Scope of the mutation | Undo log |
  | --- | --- |
  | system-wide (`/etc`, `/usr/local`, system services) | `/var/lib/<app>/undo.jsonl` (Linux), `/Library/Application Support/<app>/undo.jsonl` (macOS) |
  | user-wide (`$HOME`, dotfiles, user services) | `${XDG_STATE_HOME:-~/.local/state}/<app>/undo.jsonl` |
  | project or folder (files under a working directory) | `<folder>/.<app>/undo.jsonl`, git-ignored — not in `.cache/`, which must stay safe to delete |

  An action spanning several scopes writes a record in each.
- **A record** holds: id, time, the command and run it belongs to, the target (path, key, row),
  its state before (a backup path, the previous value, or "absent") and after, and the inverse
  operation. Back up anything overwritten or deleted, next to the log (`backups/<id>/`).
- **Write-ahead**: write the record *before* mutating and mark it done after, so an interrupted
  action can still be undone or completed.
- **Undo** (`<cli> undo [id|run]`, default: the latest run): newest first, only if the target
  is still in its recorded "after" state — otherwise skip and say why; the undo is itself
  logged. Backups are kept until the user prunes them (`<cli> undo --prune …`).

### Suggest automating repeated work

Look out for tasks the user does by hand again and again, and propose to automate them.
- **Where to look**: the current session (the same commands or edits requested several times);
  the shell history (`~/.zsh_history`, `~/.bash_history`), for commands touching this project;
  CI and run logs; `LOGBOOK.md`, `NOTES.md` and `README.md` steps that are long manual sequences;
  `git log` (recurring chore commits, repeated fix-ups).
- **History and logs are sensitive**: read them locally and only for this purpose, extract
  command *patterns*, and never copy secrets, tokens, hostnames of customers or personal data into
  files, messages or suggestions.
- **Suggest, don't impose**: at a natural break, propose briefly what is repeated, how often, the
  automation (preferably a subcommand of the project's CLI; otherwise a script, a git hook, a CI
  job, a scheduled job or an agent skill) and what it saves. Implement it only if the user agrees;
  note accepted-but-deferred ideas in `TODO.md`, and do not repeat a suggestion the user declined.

## Project-specific notes

### Overrides of the standard rules above

These project rules take precedence over the Permissions section above.

- **Push only when explicitly requested by the user**, following the push-specific
  confirmation rules in Permissions above. Commits are fine when asked for.

### Layout

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
- `Lode/Settings.lean` — explicit operator TOML or JSON settings and environment precedence.
- `Lode/Secrets.lean` — endpoint-bound model API key versions in Typednotes Secrets.
- `Lode/Extension.lean`, `Lode/Mcp.lean` — compile-time tool catalog, typed decoders and bounded stdio MCP calls.
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

### Running tests

```
lake test          # unit tests
python3 test/settings.py     # settings and direct key handoff via real local services
lake exe lode-mcp-smoke      # compiled MCP extension subprocess
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

### Conventions

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

### Releasing

For a new release commit, the user can push main and its version tag together.
The publisher waits up to two hours for that exact commit's latest push-to-main
CI success; all existing main CI jobs remain required. Failed/cancelled CI,
invalid evidence, API errors and timeout stop publication. Existing tags retain
their original workflows and must not be moved to adopt this behavior.

### Verified contracts and remaining boundaries

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
