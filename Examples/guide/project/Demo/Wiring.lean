import Demo

namespace Demo
open Control.Monad.Effect

/-- A source-level check of the basket's payload types, available to Lean LSP.
    Lun separately checks the observable wiring and declarations in lun.json. -/
def basketPayload (value : Nat) : Eff [] Nat := do
  let doubled ← double value
  let base ← seed ()
  add doubled base

end Demo
