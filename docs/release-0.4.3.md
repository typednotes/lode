# Lode v0.4.3 (local implementation)

Adds immutable caller-owned output/source/ordered-wiring build contracts for
Typednotes v0.10.0. Session status acknowledges the validated contracts;
`lun_build` consumes private checked-manifest evidence before calling Lun's
kernel-checked type/wiring compiler. Missing pins, model overrides and message/
credential updates cannot loosen caller types. Unpinned parent outputs remain
inferred and can evolve coherently with children.

The prompt explicitly uses the existing bounded Lean LSP tool on graph wiring
and parent/child hover information. Real LSP diagnostics and the native writer/
broker/runner path verify the behavior. Input-only graphs are now permitted
without a dummy function. No new effect/tool operation or dependency pin is added.
The app must deploy this writer before automatic generation with build contracts;
fleet v0.6.3 adopts its latest digest with app migration 0013.

See [build contracts](build-contracts.md). Release commits and annotated tags are
local; source publication and deployment remain the user's actions.
