/-
  Tests for `Lode.Lun`: `lun.json` is read for its shape, the build request
  carries the published commit and the repository warrant, and lun's
  statuses read well for the model.
-/
import LodeTest.Util
import Lode.Lun

open Lean (Json fromJson?)
open Lode.Lun

namespace LodeTests.Lun

def manifest : String :=
  "{\"open\": [\"P\"], \"functions\": [{\"name\": \"double\", \"module\": \"P.M\", \"function\": \"P.double\", \"signature\": \"Nat → Eff [] Nat\"}], \"graphs\": []}"

#guard (parseManifest manifest).toOption.isSome
#guard (parseManifest "{\"functions\": []}").toOption.isNone
-- lun's pre-0.2.0 vocabulary is refused, naming the new key.
#guard match parseManifest "{\"cells\": [{}]}" with
  | .error e => (e.splitOn "is now \"functions\"").length > 1
  | .ok _ => false
#guard match parseManifest "{\"functions\": [{}], \"dags\": []}" with
  | .error e => (e.splitOn "is now \"graphs\"").length > 1
  | .ok _ => false
#guard (parseManifest "[1]").toOption.isNone
#guard (parseManifest "{\"functions\": [{}], \"graphs\": 3}").toOption.isNone

def src : Lode.Workspace.Source :=
  { repo := { host := .github, segments := ["o", "r"], cloneUrl := "https://github.com/o/r.git" }
    branch := "main", path := "lean" }

def req := buildRequest src ("".pushn 'a' 40) none ((parseManifest manifest).toOption.getD { functions := #[] })

#guard (req.getObjVal? "source" >>= (·.getObjValAs? String "commit")) == .ok ("".pushn 'a' 40)
#guard (req.getObjVal? "source" >>= (·.getObjValAs? String "path")) == .ok "lean"
#guard (req.getObjVal? "source" >>= (·.getObjValAs? Json "credentials")) == .ok Json.null
#guard (req.getObjValAs? (Array Json) "functions").toOption.map (·.size) == some 1
#guard (req.getObjValAs? (Array Json) "graphs").toOption.map (·.size) == some 0
#guard (req.getObjVal? "cells").toOption.isNone
#guard (req.getObjValAs? (Array String) "open") == .ok #["P"]
-- Absent fields are `null`, which lun reads as absent.
#guard ((buildRequest { src with path := "" } "c" none { functions := #[] }).getObjVal? "source" >>=
  (·.getObjValAs? Json "path")) == .ok Json.null
#guard ((buildRequest src "c" none { functions := #[] }).getObjValAs? Json "graphs") == .ok Json.null

-- lun's answers, read through derived shapes.
def diag (j : Json) : Diagnostic := (fromJson? j).toOption.getD {}
def status (j : Json) : Status := (fromJson? j).toOption.getD { id := "?", state := "?" }

#guard renderDiagnostic (diag (Json.mkObj [("scope", "function"), ("name", "double"), ("file", "P/M.lean"),
  ("line", (3 : Nat)), ("column", (4 : Nat)), ("severity", "error"), ("message", "type mismatch")])) ==
  "[function double] P/M.lean:3:4: error: type mismatch"
#guard renderDiagnostic (diag (Json.mkObj [("scope", "graph"), ("name", "main"), ("line", (2 : Nat)),
  ("column", (1 : Nat)), ("message", "unknown"), ("hint", "h")])) == "[graph main] line 2:1: error: unknown\n  hint: h"
#guard (renderStatus (status (Json.mkObj [("id", "b"), ("state", "ready"), ("diagnostics", Json.arr #[]),
  ("functions", Json.arr #[Json.mkObj [("name", "double")]]), ("graphs", Json.arr #[])]))).startsWith
  "lun build b: ready\n\nfunctions: double\ngraphs: "
#guard (renderStatus (status (Json.mkObj [("id", "b"), ("state", "failed"), ("error", "the build failed"),
  ("diagnostics", Json.arr #[Json.mkObj [("scope", "function"), ("name", "d"), ("message", "m")]])]))) ==
  "lun build b: failed\nerror: the build failed\n\n1 diagnostic(s):\n[function d] error: m"
-- A status without an id or state is not a status.
#guard (fromJson? (Json.mkObj [("state", "ready")]) : Except String Status).toOption.isNone
#guard finished "ready" && finished "failed" && !finished "building"

end LodeTests.Lun
