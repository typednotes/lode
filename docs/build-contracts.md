# Caller-owned graph type contracts (0.4.3)

The authenticated app supplies optional `buildContracts` on session creation:

```json
{"outputs":{"parent":"Nat"},"inputs":{"value":"Nat"},
 "dependencies":{"parent":["value"]},"graph":"main"}
```

Only user configuration supplies pins. Generated signatures and a previous
implementation's inferred output are not pins. Unlisted outputs may evolve;
update parent implementations, dependent argument types and graph wiring together.
Effects and resource authority still cannot widen. When a user pin conflicts,
report it rather than alter the pin or introduce a broader operation.

Lode validates bounded type/name/ordered-dependency maps, stores them in session
metadata and acknowledges them in status. They are immutable across messages,
credential refresh and restart. The app refuses an older writer that does not
acknowledge exactly its caller contracts, before sending generation messages.
New declarations open a fresh bounded writer rather than expand an existing
session's allowed function names/grants.

`lun_build` overlays caller output/source/wiring data on the published manifest
and consumes private `PinnedManifest` evidence (`outputsPreserved`,
`graphPreserved`). Omitted pinned functions/graphs refuse. Model-written output
overrides are replaced by caller pins. Lun then generates kernel-checked
OutputContract, SourceContract and WiringContract equalities for the actual
compiled graph. Trials and final app adoption use the same caller metadata.

The prompt asks for a typed Lean graph-wiring file, LSP diagnostics on that file,
and hover on parents/children when signatures disagree, plus `check` and the
actual constrained `lun_build`. The existing [LSP dispatcher](lsp.md) supports
this through proof-bounded read-only methods; no extra RPC/process permission or
raw IO fallback is added. Diagnostics can accept a coherent unpinned parent
Nat-to-String change while a conflicting fixed Nat annotation fails.

Verified: Lean pin/refusal witnesses, the real LSP server (66 dispatcher calls),
and the app → actual Lode → real broker → local Git → compiled Lun pipeline,
including writer build trials. Build tooling/container/FFI and the authenticated
app's configuration provenance remain the existing trusted boundaries.
