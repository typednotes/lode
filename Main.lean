import Lode.App
import Lode.Extensions.Lean

/-- Run Lode with the tools selected at compile time. -/
def main (args : List String) : IO UInt32 :=
  Lode.App.main (Lode.Extension.Catalog.check [Lode.Extensions.leanVersion]) args
