/- Compile-time tools and the minimal runtime context they receive. -/
import Lean.Data.Json

namespace Lode.Extension

open Lean (Json)

/-- Execution context for trusted compiled tools. -/
structure Context where
  project : System.FilePath
  abort : IO.Ref Bool
  timeoutMs : Nat

/-- A compiled tool couples its argument type and decoder to its handler. -/
structure Tool where
  private mk ::
  name : String
  description : String
  schema : Json
  handle : Context → Json → IO (String × Bool)

/-- Build a tool whose JSON decoder and handler agree on the argument type. -/
def Tool.define (name description : String) (schema : Json) (parse : Json → Except String α)
    (run : Context → α → IO (String × Bool)) : Tool :=
  ⟨name, description, schema, fun ctx arguments =>
    match parse arguments with
    | .error error => pure (s!"invalid extension arguments: {error}", true)
    | .ok input => run ctx input⟩

/-- The catalog is selected by the executable. Duplicate names are rejected. -/
structure Catalog where
  private mk ::
  tools : List Tool
  unique : (tools.map (·.name)).Nodup

/-- The empty catalog works for deployments that compile without extensions. -/
def Catalog.empty : Catalog := ⟨[], by simp⟩

/-- Check the static tool table before opening the server or running a task. -/
def Catalog.check (tools : List Tool) : Except String Catalog := do
  unless tools.all (fun tool => !tool.name.isEmpty && tool.name.length ≤ 64 &&
      tool.name.all (fun c => c.toNat < 128 && (c.isAlphanum || c == '_'))) do
    throw "extension tool names must contain 1–64 ASCII letters, digits or underscores"
  if h : (tools.map (·.name)).Nodup then pure ⟨tools, h⟩
  else throw "extension tool names must be unique"

/-- Decode arguments with the selected tool before running its handler. -/
def Catalog.dispatch (catalog : Catalog) (ctx : Context) (name : String) (arguments : Json) :
    IO (String × Bool) := do
  let some tool := catalog.tools.find? (·.name == name) | return ("unknown compiled extension tool", true)
  tool.handle ctx arguments

end Lode.Extension
