import Linen.Control.Monad.Effect

namespace Demo
open Control.Monad.Effect

/-- Twice a natural number, with no runtime effects. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- Sum two values; Lun decodes them from one ordered JSON input array. -/
def add (a b : Nat) : Eff [] Nat := pure (a + b)

/-- A constant source: Unit means there is no user-supplied JSON argument. -/
def seed : Unit → Eff [] Nat := fun _ => pure 10

end Demo
