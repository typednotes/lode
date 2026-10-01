# Caller-owned Eff trials

`lun_call` runs the same compiled, capability-indexed `Eff` functions and graphs
as the app. Lode has no generic database, vault, credentialed HTTP or arbitrary
IO execution tool. The model supplies input only; the authenticated app supplies
authority separately. The operator's model key grants no runtime effects.

## Wire contract

The app attaches `execution` to `POST /v0/sessions` before starting the model:

```json
{
  "execution": {
    "policy": {"effects": ["HTTP", "Trace"], "domains": ["example.org"]},
    "binding": {"org_id": "ORG", "user_id": "ACTOR", "graph_id": "GRAPH"},
    "functions": ["fetch", "traced"],
    "graphs": ["main"],
    "connectors": {}
  }
}
```

This is an excerpt from a session request, not a new model tool argument. A
configured bearer token is required whenever execution authority is attached.
Missing authority retains standalone input-only execution: an ungranted `Trace`
still fails. Authority cannot be attached later to such a legacy session.

`connectors` uses Lun's native function-name → grant-array contract unchanged.
Each grant contains provider, connection, credential-owner account, the typed
organization/connection/cell/warrant ceilings, and fresh operation-specific
`warrants` with explicit costs. Omitted `warrantPermissions` means the cell
ceiling, as in Lun. All local-service accounts belong to the execution **actor**;
external accounts belong to their actual credential **owner**, who may differ
from the actor. Vault grants are bound to the graph. The app reuses its real
graph grant minting/provisioning path, including the live organization,
connection and warrant-keyed vault documents.

The envelope permits only `policy`, `binding`, `functions`, `graphs`, and
`connectors`. `policy` permits only `effects` and `domains`. Runtime credentials,
transport URLs, `_runtime`, operator keys and input fields are refused. Lun
injects its private service configuration after compilation.

## Lifecycle and execution witnesses

- `Context.parse` is the private-constructor boundary; it uses Linen's typed
  capability parser and Lun's session-grant decoder.
- Authenticated HTTP ingress attaches a private `Caller` witness checked against
  the configured service bearer. Dispatch re-binds it to the session's actual
  configuration; `Call.authenticated` excludes no-token standalone ingress from
  authority-bearing calls. This evidence is memory-only and never serialized.
- `Bounded` carries Lun `ExecutionRefresh` evidence against **both** the
  immutable launch ceiling and the previous public ceiling. Function/graph names
  can only shrink. Bindings, provider, connection, account and bucket cannot
  change. Accepted updates cannot restore removed scopes or byte limits.
- `POST …/messages` carries top-level `execution` for narrowing or replacing
  fresh tokens. `PUT …/credentials` may carry `execution` only when its public
  bounds equal the current bounds exactly; policy edits belong on messages.
  Invalid policy/identity transitions are refused before changing credentials or
  metadata. Refreshed tokens are independently checked again at effect dispatch.
- The policy mutex serializes these transitions with actual tool execution.
  Manifest services outside the caller's name list fail before build submission.
- `FreshOperation` carries validity of all supplied operation caveats at the
  dispatch instant, including expiry/budget presence and organization binding.
  `Request.ofWarrant` alone is only a request decoder, not permission evidence.
- The private `Call` constructor binds the selected service and exact input-only
  body to the bounded context and freshness witnesses. `Lode.Lun.call` consumes
  that witness; it cannot receive a raw model-selected execution body.
- `Call.authority_correspondence`, `Call.dispatch_attenuated`, and
  `Call.dispatch_current_attenuated` prove that the **actual outbound envelope**
  is bounded by launch and previous authority. `grant_attenuation` reuses Lun's
  four independent narrowing proofs. `four_ceiling_correspondence` reuses Linen's
  execution authority and proves all four resource permissions simultaneously.

`executionCeiling` and `executionBounds` persist only Lun's public projection:
bindings, effects/domains, names and ceiling metadata. No operation tokens,
warrant tags, runtime passwords or credential keys are stored or shown to the
model. After restart every credential is absent; a bounded trial refuses until
the caller refreshes. Status exposes the public bounds and the boolean
`credentials.execution`, never the tokens.

The app intersects newly minted grants with these current bounds before sending
them. An organization policy or cell/graph declaration edit conservatively revokes **all** outstanding
writer effect authority before acknowledgment, including anonymous HTTP/files
which have no broker authority row. Existing writers cannot regain those effects
through refresh or restart. A newly authorized app launch obtains new bounds.
The final writer-binding transaction records the session in the graph under the
organization lock and re-reads current policy/cell names before generation. This
closes the mint → open → register race: an edit sees the writer or invalidates its
fresh grants; stale launch policy cannot be republished after acknowledgment.

## Verification and trusted boundaries

Build in the coordinated sibling override workspace:

```sh
lake build lode:exe +LodeTest
```

The app's `scripts/test_native_connectors.py --runtime --real-writer` includes
`lode_runtime_bridge_cases.py`. It executes real app-minted grants through the
compiled Lode tool callback and compiled Lun: SCRAM PostgreSQL insert/select,
graph-vault reads, descriptor-relative temporary files, anonymous HTTP,
authorized Trace, a graph trial and a real HMAC-brokered shared-owner connector.
It also checks model policy injection, undeclared names, schema/secret/private-IP
refusals, all four independent native ceilings before credential resolution,
protected PUT refresh, expiry before effects, compiled-server restart and live
policy revocation. Existing ungranted-Trace and input-only graph tests remain.

Anonymous HTTP is entirely local in this fixture. A test-only libc interposer
resolves one reserved fixture hostname to a public address and routes the pinned
socket to a loopback HTTP peer. Runtime method/domain/port/public-address checks
remain unchanged; no external network request or production bypass is used.

The authenticated app, its database/vault projections, Lun's interpreter and
library/FFI/container boundaries remain trusted. Native HMAC verification and
live external credential policy execute at Liaison; local DB/vault authenticity
retains Lun's existing authenticated-app/trusted-vault boundary. These proofs do
not make allowed `bash`, project Lakefiles, or the writer process a general
sandbox, and do not establish live paid-provider/model conformance.

Lode pins Lun's current source commit for its session projection and pure
narrowing functions; no new release tag is required. Rebuild/deploy app, Lode and
the coordinated bounded Lun together. Old writer sessions without a launch
execution ceiling must be replaced by a newly authenticated app launch.

Deployment release pair: **Lode v0.4.1 and Typednotes v0.7.0**. Lun v0.3.0,
Liaison v0.6.0 and Linen v1.10.0 remain the published runtime/SDK dependencies.
Push and verify the Lode release before publishing the app release; deploy the
pair after both images and CI checks pass. See the app's `docs/push-order.md`.
