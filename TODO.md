# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28), done in
lode 0.2.0 with linen 1.7.0 (and lun 0.2.2, liaison 0.5.5 in the same pass).
What remains is noted per item.

## Broken now (independent of linen)

- [x] **lode speaks lun's old API.** lode speaks lun 0.2.0's functions and
  graphs throughout (the old keys are refused with a hint), and CI pins lun.

## Shared with lun — moved into linen

- [x] **Process runner with deadline** → `System.Process` (linen 1.7.0).
  `Lode/Process.lean` keeps only lode's environments (`hermeticGit` with an
  identity, `toolEnv`). The move found a bug: after `Child.takeStdin`, Lean
  4.34's `Child.kill` signals the leader only, so at a deadline or an abort a
  `lake build`'s workers kept running and held the pipes past the deadline.
  linen kills the group explicitly. linen's `System.GitFn.Build` now runs its
  steps under a deadline too.
- [x] **lake log diagnostics parser** → `System.LakeLog`; `Lode/Diagnostics.lean`
  is gone.
- [x] **`constantTimeEq`** → `Crypto.ConstantTime`; also used by liaison's
  `verifyTag` and linen's JWS HMAC verification.
- [x] **Branch/repo validation** → `System.Git.Remote` (`isBranchName`,
  `Repository.parse`). The codeload tarball download stays: it is three
  lines on top of liaison's answer in each service, not a building block.

## linen features lode could use

- [x] **Retry with `Retry-After` and jitter.** linen 1.7.0 split
  `parseRetryAfterMillis`/`delayFor` from `Client.Response`; `Model.complete`
  uses them with a `RetryPolicy`, follows a relayed `Retry-After`
  (`test/liaison.sh` checks it), and still stops on abort.
- [ ] **If lode ever screens generated sources with `System.GitFn.Policy`**
  (it has no leak exposure today — no in-process `importModules`): point its
  search path at the shared `{cache}/linen/{rev}`, never a session's own
  `.lake/packages/linen`, or linen keeps one environment per session for the
  life of the process. And the policy rejects `partial`, which lode's prompt
  allows (`Prompt.lean`). The natural consumer is lun. Nothing to do now.

## Workarounds that linen could remove

- [x] **`LodeTest`, not `Tests`.** linen's test library is `LinenTest` since
  1.7.0; all four packages now follow the `{Package}Test` convention of
  mathlib, batteries and aesop, as their `testDriver` (`lake test`).
- [x] **Native dependencies** come from linen: CI uses
  `typednotes/linen/.github/actions/setup-native-deps@v1.7.0`, the Dockerfile
  installs `ci/native-deps/apt.txt` at `LINEN_REF`.
- [x] **CA bundle** (`Dockerfile`). Nothing to remove, and nothing missing:
  linen's client context calls `SSL_CTX_set_default_verify_paths`
  (`linen/ffi/tls.c`), which reads `SSL_CERT_FILE`/`SSL_CERT_DIR` first and
  falls back to OpenSSL's compiled-in paths — on Ubuntu `/usr/lib/ssl`, whose
  `cert.pem` and `certs/` point at `ca-certificates`' bundle. The two `ENV`
  lines are redundant on this base but harmless, and keep the image correct on
  a base whose OpenSSL looks elsewhere. They matter only for lode's outbound
  HTTPS (the direct model transport and the codeload tarball redirect); lode
  serves plain HTTP (`git` uses its own TLS stack and the same bundle).
