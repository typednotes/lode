# Writer tools and native model transport

Lode writes repository implementation source; Lun compiles and executes the
declared `Eff` functions/graphs. Notebook regeneration and implementation-source
attachment are app-owned lifecycle operations. They must keep the declared
signature, connection identities and execution ceilings rather than giving
generated code a broader effect row.

Coordinated release set: **Lode 0.4.1, Lun 0.3.0, Typednotes 0.7.0,
Linen 1.10.0 and Liaison 0.6.0**. Package locks and runtime/image defaults use
this set. Local release tags require publication before deployment.

## App launch contract

Inject **`tools` at the top level of `POST /v0/sessions`**, as a JSON array of
exact writer-operation names:

```json
{
  "source": {"url": "https://github.com/acme/implementation", "branch": "main"},
  "tools": ["read", "ls", "grep", "write", "edit", "todo", "check"],
  "model": {
    "api": "responses",
    "name": "gpt-6",
    "baseUrl": "https://api.openai.com/v1",
    "credentials": {"account": "USER/CONNECTION", "warrant": {}, "cost": 10}
  }
}
```

The warrant above is a placeholder; supply a real broker-issued warrant. Its
capability action must be **`inference.generate`**, its provider the connection's
provider ID, and its resource the connection ID. All supplied connections must
belong to the same organization. The model/resource entitlement must be allowed
by the broker's independently stored policy. Lode never substitutes a different
account or reads provider environment keys to make a denied call work.

Known writer operations are `read`, `ls`, `grep`, `write`, `edit`, `bash`, `todo`,
`check`, `publish`, `lun_build`, `lun_call`. Omission uses the existing full
writer preset for standalone compatibility. `[]` denies every tool. `null`,
unknown names, duplicate names and non-array shapes are refused. The app sends
the organization's concrete allowlist at launch, narrows against the live
session list on subsequent messages, and acknowledges organization policy edits
only after narrowing. Omission remains a standalone compatibility preset, not
an organization-policy lookup.

The launch list is immutable. An update on `POST …/messages` may carry `tools`,
but must be a subset of the **current** list:

```json
{"text": "Continue with inspection only", "tools": ["read", "ls", "grep", "todo"]}
```

Removed operations cannot return through an agent change, credential refresh,
or restart. The selected agent's tool set is intersected with the live list for
both advertising and execution. `PUT …/credentials` rejects a `tools` key;
policy updates belong on messages. Credential refreshes preserve provider,
account and organization and re-check the fixed model's native API and action.
Invalid updates do not partially install credentials. The next model call,
including compaction, re-reads the current credentials.

Status and persisted metadata expose the current `tools`. Metadata also stores
the launch `toolCeiling` and non-secret `credentialBindings`. Older metadata
without these fields takes its current/default list as its ceiling and binds
credential identities on the first valid refresh.

## Evidence consumed by execution

`Lode.ToolPolicy` uses a finite `Operation` type. `BoundedPolicy ceiling` carries
the proof that its current policy narrows the immutable launch ceiling.
`AuthorizedArgs policy agent` carries permission for the operation derived from
the **actual parsed arguments** under both the current policy and agent.
`Tools.run` consumes this witness; the unchecked dispatcher is private.

Kernel-checked properties include reflexive/transitive narrowing,
`BoundedPolicy.authority_bounded` and
`AuthorizedArgs.authority_bounded`. The live policy mutex serializes narrowing
with tool execution, so an acknowledged narrowing cannot race an old witness
into starting a newly denied operation. An already executing tool completes
before that narrowing can be acknowledged. Metadata writes are separately
serialized so persistence cannot restore an older list after narrowing.

This is a **named writer-tool ceiling**, not a sandbox proof. If `bash` is
allowed, its commands can implement file changes without the `write` tool;
`check` runs a project's Lake configuration. The container/trust-domain
boundary, filesystem races, HTTP transport and credential broker remain trusted
runtime boundaries. Neither a model prompt nor an allowlist can make arbitrary
shell execution semantically read-only.

`lun_call` accepts input data only: function `input` or `inputs`, graph
`inputs`. The model cannot inject top-level execution policy, authority
bindings, connector grants or credentials through this tool. Such context is
owned by the app/runtime, and is not inferred from generated implementations.
Its parsed `RuntimeInput` is an inductive input-only shape with no arbitrary
request-body constructor; `RuntimeInput.input_only` proves its emitted top-level
field is `input` or `inputs`.

## Native broker request

Lode builds the envelope with `Liaison.Wire.Body.connector`, checking account
and action against the warrant. It sends the original native JSON request as
`payload` text and has no URL, method, credentials or raw header override:

```json
{
  "warrant": {},
  "now": "1790726400",
  "cost": "10",
  "provider": "opencode-go",
  "action": "inference.generate",
  "resource": "CONNECTION",
  "runId": "WARRANT_RUN",
  "orgId": "ORG",
  "call": {
    "kind": "connector",
    "account": "USER/CONNECTION",
    "operation": "inference.generate",
    "resource": ["qwen3.8-max"],
    "payload": "{\"messages\":[]}",
    "context": {
      "sessionId": "LODE_SESSION_ID",
      "initiator": "agent",
      "client": "typednotes-lode"
    }
  }
}
```

Top-level grant fields come from the warrant, never from model output. The
`runId` is a warrant's run binding; **it is not the conversation ID**.
`context.sessionId` is the actual persisted `Session.id`, unchanged across
steering, retries, compaction, credential refresh and restart. The initiator is
`user` for a user-led next turn and `agent` for tool continuations and compaction.
Lode identifies itself as `typednotes-lode`, never as an approved third-party
client. Radius also receives this session ID in `options.sessionId`.

### Verified broker contract

The app creates the Lode checkout/session without an initial model message,
obtains its actual persisted ID, binds trusted conversation/publication run
projections, and then starts the writer. `conversation:{sessionId,allowedTools}`
and `publication:{branch,root:["typednotes",graph-slug]}` are graph-bound
server-owned refinements; refresh preserves identity and narrows tools.
Repository credentials have a primary `repositories.read` warrant plus named
`operations` tokens for `repositories.write`; removals also require independently
scoped `repositories.delete` authority in the publication plan's ceilings.

Lode passes `context` through the actual `Liaison.Wire.ConnectorCall` SDK;
it does not mutate the serialized body to invent a field. The broker validates
it against trusted run `conversation:{sessionId,allowedTools}` metadata and
derives gateway headers:

- OpenCode Go (all protocols, including auxiliary calls): its own client
  `User-Agent` and `x-opencode-session = context.sessionId`.
- Copilot: the truthful client identity, `x-initiator = context.initiator`, and
  the broker's supported conversation intent. Do not permit caller-selected
  arbitrary headers, URLs or approved-client impersonation.
- Native request allowlists accept Lode's bounded **local function tools**,
  while denying provider-hosted tools/callbacks/routing that can escape the
  selected authority. Lode strips `model` from the payload; the native resource
  selector owns it. Native top-level fields include `tools`,
  Responses `store:false` and `include:["reasoning.encrypted_content"]`, and
  Gemini `tools`/`functionDeclarations`. Responses function specs explicitly
  use `strict:false` because writer schemas contain optional properties.
- Radius `inference.generate` uses the verified Pi payload adapter and SSE
  transport. Production `supportsApi/checkProtocol` now enables it; the linked
  real-broker fixture exercises `Model.complete`, not a validation bypass.
- The requested model selector splits namespaced IDs into plain components,
  matching app grants; Gemini's `models/` catalog prefix is removed.
  `Wire.validResource` refuses `/` within a component, so namespaced model grants
  must use the same component splitting as the request.

Generic `Body.provider` is never a fallback. Workspace reads immutable branch,
tree and per-file native views, then publishes a scoped atomic commit plan.
Mixed removals require independently granted `repositories.delete` selectors in
the trusted write projection. Publication additionally binds the branch/project
root. The real broker/Lode fixtures exercise both repository backends, model
replay, races and deletion denials. The full app fixture additionally verifies
app provisioning, generation, publication and actual Lun adoption.

Retired function references are not replay authority. `Model.boundedHistory`
recovers after the latest denied/retired exchange, keeps the user task and removes
that exchange's call/result IDs instead of widening policy or using raw HTTP.
Fully permitted reasoning/signature replay is unchanged. The original message
stream determines the truthful initiator even when recovery emits a text summary.

## Native protocol behavior

`Config.api` accepts `anthropic`, `openai` (Chat), `responses`, `gemini`, `pi`,
and local-only `scripted`. Thirty-seven generative provider IDs are accepted;
TypeSafe and OpenCode `jev-*` classifiers cannot drive a writer. Gateway API
selection is checked against both provider and model, including Go MiniMax
Messages, Zen `qwen3.8-max` Chat versus Go Messages, Muse Spark Responses,
Copilot GPT-4.1/4o/GPT-5-mini Chat, other Copilot GPT ≥5 Responses, and OpenAI
GPT ≥5 plus o1/o3/o4 Responses. The app should pass its explicit native `api`
and configured `baseUrl`; a mismatched native API is refused.

- Responses uses `store:false`, requests encrypted reasoning, and replays the
  ordered native output items before function-call outputs. Incomplete token
  limits normalize to continuation; incomplete function calls never execute.
- Messages preserves signed/redacted thinking blocks; Chat preserves
  `reasoning_content`, including text-only assistant turns. Chat reasoning
  models receive `max_completion_tokens`.
- Gemini preserves full signed parts, including text-part thought signatures,
  and echoes supplied native function IDs in results. `MAX_TOKENS` continues;
  safety/unsupported endings fail.
- Pi uses the current normalized transcript: system `toolsAdded` and timestamp,
  user/assistant/tool-result messages, session options, and buffered SSE.
  Thinking/text/tool signatures replay in order. A recognized terminal event
  and complete content/tool blocks are mandatory; errors, unknown reasons,
  duplicate IDs and truncated streams fail.
- Cached tokens are excluded from fresh input counts for Chat/Responses/Gemini.
  Reported inconsistent cached usage is refused. Messages/Pi retain their
  independently reported input/cache counters.

No OAuth exchange is implemented in Lode. Copilot's direct bearer is an
**inference access token**, not a generic GitHub PAT. Production auth comes
from the entitled broker connection. Copilot OAuth exchange/refresh, supported
static header credentials and actual account/model entitlements remain the
broker/app owners' responsibility. No live credential or billed inference was
used to verify these adapters.

## Checks

The local four-package workspace verifies sibling development before publication:

```sh
LEAN_NUM_THREADS=2 lake build lode:exe +LodeTest
```

Then from the Lode checkout:

```sh
python3 test/native.py .lake/build/bin/lode
LODE_TEST_BINARY="$PWD/.lake/build/bin/lode" bash test/liaison.sh
```

`test/native.py` passes twelve native protocol/gateway cases plus compaction,
in-flight narrowing/refresh and restart with a
real writer and fake broker: URL-free requests, tool replay, denied execution,
usage, retries, continuation, compaction, in-flight narrowing/credential
refresh, atomic failed updates and restart persistence. Fixtures contain no
real credentials. The liaison fixture's former repository-race push was
replaced with local fetch/update-ref plumbing before running it.

The independent Liaison suite passes **655 real HTTP cases**, covering all
**54 providers / 165 supported provider-operation pairs** with zero unsupported
advertised pairs. It executes compiled Lode model and Workspace callers, actual
broker HMAC/SQL/vault authorization and local Git head/ref processing, including
positive continuations, deletion denials and concurrent rewinds.

From the app checkout, the full integration fixture is:

```sh
python3 scripts/test_native_connectors.py --temp-root "$APPROVED_TEMP_ROOT" \
  --runtime --real-writer --lean-workspace "$LOCAL_LAKE_WORKSPACE"
```

It passes app → compiled Lode → real broker → local Git → compiled Lun generation,
tool dispatch, check, scope-checked publication and adoption, plus denial cases.
Related verification passes **101 app API tests**, **24 browser groups** and
**69 compiled-runtime cases**. Provider APIs/model replies are controlled fixtures;
these results do not measure paid-provider conformance, OAuth refresh or real-model
implementation reliability. Build/container isolation, approved libraries,
filesystem/zlib/socket/TLS FFI, broker cryptography/ledger and remote ref/API
correspondence remain explicit trusted boundaries. Linux/container execution is
not claimed by these local macOS checks. The new [LSP tool](lsp.md) passes 63
actual dispatcher calls; [caller-owned Eff trials](runtime-bridge.md) pass seven
real bridge groups. There is no unrestricted web-fetch writer fallback.

Protocol references audited: [OpenAI stateless reasoning](https://developers.openai.com/api/docs/guides/reasoning),
[OpenCode Go client requirements](https://opencode.ai/docs/go/), and Pi's
current [wire adapter](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/api/pi-messages.ts)
and [transcript types](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/types.ts).
