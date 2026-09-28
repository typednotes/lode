# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28). The bump
itself needed no code change. Each item names where it comes from; re-check
before acting.

Moves into linen follow linen's `AGENTS.md` ("Importing external code"): the
linen change and the deletion here (and in lun) happen in the same pass.

## Broken now (independent of linen)

- [x] **lode speaks lun's old API.** Done: lode now speaks lun 0.2.0's functions/graphs throughout (the old keys are refused with a hint), and CI pins lun to `v0.2.0`. lun 0.2.0 (`aa24372`) renamed cells →
  functions and DAGs → graphs in routes and fields, with no aliases: lun parses
  `functions`/`graphs` (`lun/Lun/Spec.lean:174-175`) and serves
  `/v0/builds/{id}/functions|graphs/{name}` (`lun/Lun/Server.lean:122-128`).
  lode still sends `cells`/`dags` (`Lode/Lun.lean:55-56, 86-87, 125-127`) and
  calls `{kind}s` with `kind = cell|dag` (`Lun.lean:187`). The CI `lun` job
  checks out lun's default branch unpinned, so `test/lun.sh` should now fail.
  Either pin that checkout to `39e0b62`, or move `Lode/Lun.lean`, the prompt
  and `test/lun.sh` to the new names; then rewrite `AGENTS.md:162-164`. (S / M)

## Shared with lun — move into linen

- [ ] **Process runner with deadline** (`Lode/Process.lean:31-116`): lun's copy
  is a subset, and linen's GitFn runs `lake build` with no timeout
  (`linen/.../GitFn/Build.lean:89-92`). Keep lode's version as the one that
  moves. (S)
- [ ] **lake log diagnostics parser** (`Lode/Diagnostics.lean`): `parse` is
  byte-identical to lun's. (S)
- [ ] **`constantTimeEq`** (`Lode/Server.lean:59`): identical in lun; liaison's
  tag check needs one too; linen has none. (XS)
- [ ] **Branch/repo validation and codeload tarball fetch**
  (`Validate.lean:44,131`, `Workspace.lean:110,226`) are identical to lun's.
  `AGENTS.md` says "lun is a service, not a library", so agree on linen as
  their home before moving. (S–M)

## linen features lode could use

- [ ] **Retry with `Retry-After` and jitter.** `Model.complete`'s loop
  (`Model.lean:381, 424-440`) overlaps linen's `Network.HTTP.Client.Retry`, but
  that is tied to `Client.Response` and lode also retries on liaison's
  `Wire.Response` and checks its abort flag. Worth it only if linen's policy can
  be separated from the response type. (S)
- [ ] **If lode ever screens generated sources with `System.GitFn.Policy`**
  (it has no leak exposure today — no in-process `importModules`): point its
  search path at the shared `{cache}/linen/{rev}`, never a session's own
  `.lake/packages/linen`, or linen keeps one environment per session for the
  life of the process. And the policy rejects `partial`, which lode's prompt
  allows (`Prompt.lean:160`). The natural consumer is lun.

## Workarounds that linen could remove

- [ ] **`LodeTests`, not `Tests`**, because linen declares `lean_lib Tests`
  (`linen/lakefile.lean`); lun and liaison have the same workaround. Renaming
  linen's test library would free the name. (M, in linen)
- [ ] **Native dependencies** in CI and the Dockerfile are a hand copy of
  linen's; a consumer-facing list or action in linen would replace it.
- [ ] **CA bundle** (`Dockerfile:25`): linen's TLS uses only OpenSSL's
  compiled-in default paths (`linen/ffi/tls.c:553`).
