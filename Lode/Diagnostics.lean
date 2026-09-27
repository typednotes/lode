/-
  Lode.Diagnostics — `lake build`'s output, as a short list of messages

  `lake build` prints each message as `error: FILE:LINE:COL: text`, the text
  possibly continuing on following lines (lun's `Lun/Diagnostics.lean` reads
  its builds the same way). The `check` tool hands the model these messages,
  not the raw log: it is what OpenCode does with LSP diagnostics after an
  edit, with Lean's own compiler as the language server.
-/
import Lean.Data.Json

namespace Lode.Diagnostics

open Lean (Json ToJson toJson)

/-- One message. -/
structure Diagnostic where
  severity : String
  file : Option String
  line : Option Nat
  column : Option Nat
  message : String
  deriving DecidableEq, Repr, Inhabited

/-- Line prefixes that start something other than a continuation. -/
private def starters : List String :=
  ["error: ", "warning: ", "info: ", "trace: ", "✖ ", "✔ ", "⚠ ", "Some required targets", "Build completed"]

/-- Split `FILE:LINE:COL: text`. -/
def splitLocation (s : String) : Option String × Option Nat × Option Nat × String :=
  match s.splitOn ":" with
  | file :: line :: col :: rest =>
    match line.toNat?, col.trimAscii.toString.toNat? with
    | some l, some c =>
      (some file, some l, some c, (":".intercalate rest).trimAsciiStart.toString)
    | _, _ => (none, none, none, s)
  | _ => (none, none, none, s)

/-- The `error:` and `warning:` messages of a lake log, in order. -/
def parse (log : String) : List Diagnostic :=
  let lines := log.splitOn "\n"
  let (done, cur) := lines.foldl (init := (([] : List Diagnostic), (none : Option Diagnostic)))
    fun (done, cur) line =>
      let flush := match cur with | some d => d :: done | none => done
      let start (sev pfx : String) : Option Diagnostic :=
        if line.startsWith pfx then
          let (file, l, c, text) := splitLocation (line.drop pfx.length).toString
          some { severity := sev, file, line := l, column := c, message := text }
        else none
      match start "error" "error: " <|> start "warning" "warning: " with
      | some d => (flush, some d)
      | none =>
        if starters.any (fun (p : String) => line.startsWith p) then (flush, none)
        else match cur with
          | some d => (done, some { d with message := d.message ++ "\n" ++ line })
          | none => (done, none)
  let all := (match cur with | some d => d :: done | none => done).reverse
  all.map fun d => { d with message := d.message.trimAsciiEnd.toString }

/-- `FILE:LINE:COL: severity: message`, one per diagnostic, as the model
    reads them. -/
def Diagnostic.render (d : Diagnostic) : String :=
  let loc := match d.file, d.line, d.column with
    | some f, some l, some c => s!"{f}:{l}:{c}: "
    | some f, _, _ => s!"{f}: "
    | none, _, _ => ""
  s!"{loc}{d.severity}: {d.message}"

/-- Lake's summary of which targets failed, noise the diagnostics repeat. -/
def isNoise (d : Diagnostic) : Bool :=
  d.file.isNone && (d.message.startsWith "build failed" ||
    (d.message.splitOn "logged failures").length > 1)

instance : ToJson Diagnostic where
  toJson d := Json.mkObj <|
    [("severity", toJson d.severity), ("message", toJson d.message)] ++
    (d.file.map fun f => [("file", toJson f)]).getD [] ++
    (d.line.map fun l => [("line", toJson l)]).getD [] ++
    (d.column.map fun c => [("column", toJson c)]).getD []

end Lode.Diagnostics
